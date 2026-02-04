/// Represents a single item in the fuzzy finder.
///
/// Text is stored in a shared ``TextBuffer`` (one contiguous ``[UInt8]`` for the
/// entire input).  Each ``Item`` records only an ``(offset, length)`` window into
/// that buffer, eliminating the per-item ``String`` heap allocation that dominates
/// RSS for large inputs.
///
/// ``text`` is a computed property that constructs a ``String`` on demand; use it
/// only on the cold path (rendering, output).  The matching hot path accesses the
/// raw bytes through ``TextBuffer.withBytes`` instead.
struct Item: Sendable {
    let index: Int
    /// Shared backing store.  All items produced by the same ``ItemCache`` point
    /// to the same instance.
    let buffer: TextBuffer
    /// Byte offset into ``buffer``.
    let offset: UInt32
    /// Byte length inside ``buffer``.
    let length: UInt32

    /// Lazily-constructed ``String`` view.  Allocates; prefer raw-byte access on
    /// the hot path.
    var text: String {
        buffer.string(at: offset, length: length)
    }
}
