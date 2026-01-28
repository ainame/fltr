import Foundation

/// Virtual screen buffer for efficient terminal rendering.
///
/// A double-buffered approach to terminal rendering that:
/// - Maintains an in-memory character grid
/// - Supports positioned text writing
/// - Enables efficient screen updates
public struct Screen {
    public let rows: Int
    public let cols: Int
    private var buffer: [[Character]]

    /// Creates a new screen buffer.
    ///
    /// - Parameters:
    ///   - rows: Number of rows
    ///   - cols: Number of columns
    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.buffer = Array(repeating: Array(repeating: " ", count: cols), count: rows)
    }

    /// Writes text at the specified position.
    ///
    /// - Parameters:
    ///   - text: The text to write
    ///   - row: Row position (0-indexed)
    ///   - col: Column position (0-indexed)
    public mutating func write(_ text: String, row: Int, col: Int) {
        guard row < rows, col < cols else { return }

        var currentCol = col
        for char in text {
            guard currentCol < cols else { break }
            buffer[row][currentCol] = char
            currentCol += 1
        }
    }

    /// Clears the entire screen buffer.
    public mutating func clear() {
        for row in 0..<rows {
            for col in 0..<cols {
                buffer[row][col] = " "
            }
        }
    }

    /// Gets the rendered content for a specific row.
    ///
    /// - Parameter row: Row number (0-indexed)
    /// - Returns: The row content as a string
    public func getRow(_ row: Int) -> String {
        guard row < rows else { return "" }
        return String(buffer[row])
    }
}
