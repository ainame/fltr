import Foundation

/// Result of a fuzzy match operation
struct MatchResult: Sendable {
    let score: Int
    let positions: [Int]  // Indices in the text where pattern chars matched

    init(score: Int, positions: [Int]) {
        self.score = score
        self.positions = positions
    }
}
