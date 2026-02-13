#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Append-only contiguous byte store for all item text.
///
/// Every line read from stdin is appended into a single contiguous buffer.
/// Each ``Item`` records an ``(offset, length)`` window into this buffer
/// instead of owning its own ``String``.  This eliminates ~50 bytes of
/// per-item allocator overhead (malloc header + padding) that individual
/// ``String`` heap buffers incur.
///
/// ### Backing store
/// By default the buffer is a Swift ``[UInt8]`` array.  When the
/// ``MmapBuffer`` package trait is enabled (``swift build --traits MmapBuffer``),
/// the backing store is an ``mmap``-based buffer that bypasses macOS
/// libmalloc's zone allocator, eliminating ~120 MB of speculative
/// ``MALLOC_LARGE`` pre-allocation for large inputs.
///
/// ### Sendable safety
/// A ``pthread_rwlock_t`` protects all access to the backing store.
/// Multiple readers (matching tasks) can hold the read lock concurrently;
/// the single writer (``StdinReader``) acquires an exclusive write lock only
/// for the duration of each append — typically microseconds per line.
final class TextBuffer: @unchecked Sendable {
    #if MmapBuffer
    private let storage: MmapBuffer
    #else
    /// Raw UTF-8 bytes of all lines, concatenated without separators.
    private var bytes: [UInt8] = []
    #endif

    /// Read-write lock: concurrent readers, exclusive writer.
    private let rwlock: UnsafeMutablePointer<pthread_rwlock_t>

    init() {
        rwlock = .allocate(capacity: 1)
        rwlock.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(rwlock, nil)
        #if MmapBuffer
        storage = MmapBuffer()
        #else
        bytes.reserveCapacity(1 << 20)   // 1 MB initial reservation
        #endif
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
        #if MmapBuffer
        let (off, len) = storage.append(text)
        return (UInt32(off), UInt32(len))
        #else
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
        #endif
    }

    /// Append a slice of a raw byte buffer directly — no ``String`` is created.
    /// *src* must remain valid for the duration of the call.
    func appendRaw(_ src: UnsafeBufferPointer<UInt8>, offset: Int, length: Int) -> (offset: UInt32, length: UInt32) {
        pthread_rwlock_wrlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        #if MmapBuffer
        let (off, len) = storage.append(
            from: src.baseAddress!, srcOffset: offset, length: length)
        return (UInt32(off), UInt32(len))
        #else
        let writeOffset = UInt32(bytes.count)
        bytes.append(contentsOf: UnsafeBufferPointer(start: src.baseAddress! + offset, count: length))
        return (writeOffset, UInt32(length))
        #endif
    }

    /// Return a ``String`` view of the region ``[offset, offset+length)``.
    /// Allocates a new ``String``; call only on the cold path (rendering, output).
    func string(at offset: UInt32, length: UInt32) -> String {
        pthread_rwlock_rdlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        #if MmapBuffer
        let buf = storage.bufferPointer
        let start = buf.baseAddress! + Int(offset)
        return String(decoding: UnsafeBufferPointer(start: start, count: Int(length)), as: UTF8.self)
        #else
        return bytes.withUnsafeBufferPointer { buf in
            let start = buf.baseAddress! + Int(offset)
            return String(decoding: UnsafeBufferPointer(start: start, count: Int(length)), as: UTF8.self)
        }
        #endif
    }

    /// Execute *body* with an ``UnsafeBufferPointer`` over the entire byte store.
    /// Callers slice individual items out of the pointer using their offset+length.
    /// The read lock is held for the duration of *body*, preventing concurrent
    /// reallocation by the writer.  Multiple readers can proceed in parallel.
    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        pthread_rwlock_rdlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        #if MmapBuffer
        return try body(storage.bufferPointer)
        #else
        return try bytes.withUnsafeBufferPointer(body)
        #endif
    }

    /// Reclaim unused memory after the last append (stdin EOF).
    ///
    /// With ``MmapBuffer``: releases pages beyond the written region back to
    /// the OS via ``madvise``, actually reducing reported RSS.
    /// Without: attempts to reallocate the backing array at exact capacity.
    func shrinkToFit() {
        pthread_rwlock_wrlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        #if MmapBuffer
        storage.releaseUnusedPages()
        #else
        guard bytes.capacity > bytes.count else { return }
        bytes = Array(bytes)
        #endif
    }
}
