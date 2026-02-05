/// Represents a single item in the fuzzy finder.
///
/// Text is stored in a shared ``TextBuffer`` (one contiguous ``[UInt8]`` for the
/// entire input).  Each ``Item`` records only an ``(offset, length)`` window into
/// that buffer, eliminating the per-item ``String`` heap allocation that dominates
/// RSS for large inputs.  The ``TextBuffer`` reference itself is *not* stored here
/// — it is threaded explicitly through the hot path (matching, rendering) so that
/// every ``Item`` is exactly 12 bytes (Int32 + UInt32 + UInt32).
struct Item: Sendable {
    /// The type used for item indices everywhere in the codebase.
    typealias Index = Int32

    /// Original insertion order.  Fits in Int32 for inputs up to ~2 billion lines.
    let index: Index
    /// Byte offset into the shared ``TextBuffer``.
    let offset: UInt32
    /// Byte length inside the shared ``TextBuffer``.
    let length: UInt32

    /// Construct a ``String`` from this item's byte window.  Allocates; call only
    /// on the cold path (rendering, output).
    func text(in buffer: TextBuffer) -> String {
        buffer.string(at: offset, length: length)
    }
}
