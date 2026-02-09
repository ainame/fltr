/// Virtual screen buffer for efficient terminal rendering.
///
/// Uses a flat `[UInt8]` buffer (1 byte per cell) instead of `[[Character]]`
/// (16 bytes per cell), yielding ~16x less memory and a single heap allocation
/// instead of one per row. Clearing is a `memset`-equivalent operation.
///
/// Trade-off: cells store UTF-8 code units, not full grapheme clusters.
/// For terminal rendering this is appropriate — display-width calculations
/// are handled externally by `TextRenderer`.
public struct Screen: Sendable {
    public let rows: Int
    public let cols: Int
    private var buffer: [UInt8]

    /// Creates a new screen buffer filled with spaces.
    ///
    /// - Parameters:
    ///   - rows: Number of rows
    ///   - cols: Number of columns
    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.buffer = [UInt8](repeating: 0x20, count: rows * cols)
    }

    /// Writes text at the specified position.
    ///
    /// Characters beyond the right edge of the row are silently clipped.
    ///
    /// - Parameters:
    ///   - text: The text to write
    ///   - row: Row position (0-indexed)
    ///   - col: Column position (0-indexed)
    public mutating func write(_ text: String, row: Int, col: Int) {
        guard row < rows, col < cols else { return }

        var offset = row &* cols &+ col
        let end = row &* cols &+ cols
        for byte in text.utf8 {
            guard offset < end else { break }
            buffer[offset] = byte
            offset &+= 1
        }
    }

    /// Clears the entire screen buffer (fills with spaces).
    public mutating func clear() {
        buffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            // 0x20 == ASCII space
            base.initialize(repeating: 0x20, count: ptr.count)
        }
    }

    /// Gets the rendered content for a specific row.
    ///
    /// - Parameter row: Row number (0-indexed)
    /// - Returns: The row content as a string
    public func getRow(_ row: Int) -> String {
        guard row < rows else { return "" }
        let start = row &* cols
        return String(unsafeUninitializedCapacity: cols) { dest in
            buffer.withUnsafeBufferPointer { src in
                _ = dest.initialize(fromContentsOf: src[start..<start &+ cols])
            }
            return cols
        }
    }
}
