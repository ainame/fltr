#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Append-only contiguous byte store for all item text.
///
/// Mirrors fzf's approach: every line read from stdin is appended into a single
/// growing ``[UInt8]`` array.  Each ``Item`` records an ``(offset, length)`` window
/// into this buffer instead of owning its own ``String``.  This eliminates
/// ~50 bytes of per-item allocator overhead (malloc header + padding) that
/// individual ``String`` heap buffers incur.
///
/// ### Sendable safety
/// A ``pthread_rwlock_t`` protects all access to the backing ``[UInt8]``.
/// Multiple readers (matching tasks) can hold the read lock concurrently;
/// the single writer (``StdinReader``) acquires an exclusive write lock only
/// for the duration of each append — typically microseconds per line.
/// This prevents a data race where ``Array.append`` reallocates the backing
/// storage while a concurrent reader holds an ``UnsafeBufferPointer`` into it.
final class TextBuffer: @unchecked Sendable {
    /// Raw UTF-8 bytes of all lines, concatenated without separators.
    private var bytes: [UInt8] = []

    /// Read-write lock: concurrent readers, exclusive writer.
    private let rwlock: UnsafeMutablePointer<pthread_rwlock_t>

    init() {
        rwlock = .allocate(capacity: 1)
        rwlock.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(rwlock, nil)
        bytes.reserveCapacity(1 << 20)   // 1 MB initial reservation
    }

    deinit {
        pthread_rwlock_destroy(rwlock)
        rwlock.deinitialize(count: 1)
        rwlock.deallocate()
    }

    /// Append *text* and return the ``(offset, length)`` of the written region.
    func append(_ text: String) -> (offset: UInt32, length: UInt32) {
        pthread_rwlock_wrlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        let offset = UInt32(bytes.count)
        // withContiguousStorageIfAvailable avoids an intermediate Array copy
        // for the common case where the String's UTF-8 view is already contiguous.
        let length: UInt32 = text.utf8.withContiguousStorageIfAvailable { ptr in
            bytes.append(contentsOf: ptr)
            return UInt32(ptr.count)
        } ?? {
            let arr = Array(text.utf8)
            bytes.append(contentsOf: arr)
            return UInt32(arr.count)
        }()
        return (offset, length)
    }

    /// Append a slice of a raw byte buffer directly — no ``String`` is created.
    /// *src* must remain valid for the duration of the call.
    func appendRaw(_ src: UnsafeBufferPointer<UInt8>, offset: Int, length: Int) -> (offset: UInt32, length: UInt32) {
        pthread_rwlock_wrlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        let writeOffset = UInt32(bytes.count)
        bytes.append(contentsOf: UnsafeBufferPointer(start: src.baseAddress! + offset, count: length))
        return (writeOffset, UInt32(length))
    }

    /// Return a ``String`` view of the region ``[offset, offset+length)``.
    /// Allocates a new ``String``; call only on the cold path (rendering, output).
    func string(at offset: UInt32, length: UInt32) -> String {
        pthread_rwlock_rdlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        return bytes.withUnsafeBufferPointer { buf in
            let start = buf.baseAddress! + Int(offset)
            return String(decoding: UnsafeBufferPointer(start: start, count: Int(length)), as: UTF8.self)
        }
    }

    /// Execute *body* with an ``UnsafeBufferPointer`` over the entire byte store.
    /// Callers slice individual items out of the pointer using their offset+length.
    /// The read lock is held for the duration of *body*, preventing concurrent
    /// reallocation by the writer.  Multiple readers can proceed in parallel.
    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        pthread_rwlock_rdlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        return try bytes.withUnsafeBufferPointer(body)
    }

    /// Reallocate the backing store at exactly ``count`` capacity.
    /// Call once after the last append (i.e. after stdin EOF) to reclaim the
    /// ~30 % headroom that Array's doubling growth leaves behind.
    func shrinkToFit() {
        pthread_rwlock_wrlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        guard bytes.capacity > bytes.count else { return }
        bytes = Array(bytes)
    }
}
