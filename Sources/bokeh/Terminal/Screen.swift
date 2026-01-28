import Foundation

/// Virtual screen buffer for efficient rendering
struct Screen {
    let rows: Int
    let cols: Int
    private var buffer: [[Character]]

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.buffer = Array(repeating: Array(repeating: " ", count: cols), count: rows)
    }

    /// Write text at position
    mutating func write(_ text: String, row: Int, col: Int) {
        guard row < rows, col < cols else { return }

        var currentCol = col
        for char in text {
            guard currentCol < cols else { break }
            buffer[row][currentCol] = char
            currentCol += 1
        }
    }

    /// Clear entire screen
    mutating func clear() {
        for row in 0..<rows {
            for col in 0..<cols {
                buffer[row][col] = " "
            }
        }
    }

    /// Get rendered content for a row
    func getRow(_ row: Int) -> String {
        guard row < rows else { return "" }
        return String(buffer[row])
    }
}
