import Foundation

/// A rectangular bounds for geometric calculations and hit-testing.
///
/// Uses 1-indexed coordinates (terminal convention) with inclusive boundaries.
public struct Bounds: Sendable {
    public let startRow: Int
    public let endRow: Int
    public let startCol: Int
    public let endCol: Int
    
    /// Initialize bounds with the specified coordinates.
    ///
    /// - Parameters:
    ///   - startRow: Starting row (1-indexed, inclusive)
    ///   - endRow: Ending row (1-indexed, inclusive)
    ///   - startCol: Starting column (1-indexed, inclusive)
    ///   - endCol: Ending column (1-indexed, inclusive)
    public init(startRow: Int, endRow: Int, startCol: Int, endCol: Int) {
        self.startRow = startRow
        self.endRow = endRow
        self.startCol = startCol
        self.endCol = endCol
    }
    
    /// Check if a position is within the bounds.
    ///
    /// - Parameters:
    ///   - col: Column position (1-indexed)
    ///   - row: Row position (1-indexed)
    /// - Returns: True if the position is within bounds
    public func contains(col: Int, row: Int) -> Bool {
        return row >= startRow && row <= endRow &&
               col >= startCol && col <= endCol
    }
    
    /// Width of the bounds in columns.
    public var width: Int {
        return endCol - startCol + 1
    }
    
    /// Height of the bounds in rows.
    public var height: Int {
        return endRow - startRow + 1
    }
}
