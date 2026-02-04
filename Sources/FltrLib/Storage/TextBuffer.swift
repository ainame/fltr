/// Append-only contiguous byte store for all item text.
///
/// Mirrors fzf's approach: every line read from stdin is appended into a single
/// growing ``[UInt8]`` array.  Each ``Item`` records an ``(offset, length)`` window
/// into this buffer instead of owning its own ``String``.  This eliminates
/// ~50 bytes of per-item allocator overhead (malloc header + padding) that
/// individual ``String`` heap buffers incur.
///
/// ### Sendable safety
/// The buffer is append-only; ``Item`` instances only ever reference byte ranges
/// that have already been written.  No ``Item`` is created until *after* its bytes
/// are appended (enforced by ``ItemCache.append``), so concurrent reads of
/// previously-written ranges are safe without locking.
final class TextBuffer: @unchecked Sendable {
    /// Raw UTF-8 bytes of all lines, concatenated without separators.
    private(set) var bytes: [UInt8] = []

    init() {
        bytes.reserveCapacity(1 << 20)   // 1 MB initial reservation
    }

    /// Append *text* and return the ``(offset, length)`` of the written region.
    @inlinable
    func append(_ text: String) -> (offset: UInt32, length: UInt32) {
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

    /// Return a ``String`` view of the region ``[offset, offset+length)``.
    /// Allocates a new ``String``; call only on the cold path (rendering, output).
    @inlinable
    func string(at offset: UInt32, length: UInt32) -> String {
        bytes.withUnsafeBufferPointer { buf in
            let start = buf.baseAddress! + Int(offset)
            return String(decoding: UnsafeBufferPointer(start: start, count: Int(length)), as: UTF8.self)
        }
    }

    /// Execute *body* with an ``UnsafeBufferPointer`` over the entire byte store.
    /// Callers slice individual items out of the pointer using their offset+length.
    /// This is the zero-copy hot-path accessor; the pointer is valid only inside *body*.
    @inlinable
    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer(body)
    }
}
