import Foundation

/// Result of a fuzzy match operation
public struct MatchResult: Sendable {
    public let score: Int
    public let positions: [Int]  // Indices in the text where pattern chars matched

    public init(score: Int, positions: [Int]) {
        self.score = score
        self.positions = positions
    }
}
