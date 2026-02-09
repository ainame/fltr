import Foundation

/// Result of a fuzzy match operation
public struct MatchResult: Sendable {
    /// Match score (Int16: supports scores up to 32,767, sufficient for practical use)
    public let score: Int16
    /// Character positions where pattern matched (UInt16: supports line lengths up to 65,535 bytes)
    public let positions: [UInt16]

    public init(score: Int, positions: [Int]) {
        self.score = Int16(clamping: score)
        self.positions = positions.map { UInt16(clamping: $0) }
    }

    /// Efficient initializer when positions are already UInt16
    public init(score: Int16, positions: [UInt16]) {
        self.score = score
        self.positions = positions
    }
}
