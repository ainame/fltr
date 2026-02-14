import Foundation

/// Result shape for ranking-only matching on the hot path.
/// Carries only data needed for ordering and tiebreakers.
public struct RankMatch: Sendable {
    public let score: Int16
    public let minBegin: UInt16

    public init(score: Int16, minBegin: UInt16) {
        self.score = score
        self.minBegin = minBegin
    }
}

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
