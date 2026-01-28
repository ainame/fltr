import Foundation

/// Main fuzzy matching interface
struct FuzzyMatcher: Sendable {
    let caseSensitive: Bool

    init(caseSensitive: Bool = false) {
        self.caseSensitive = caseSensitive
    }

    /// Match a pattern against text
    /// Supports space-separated tokens as AND operator (all tokens must match)
    func match(pattern: String, text: String) -> MatchResult? {
        // Split pattern by whitespace for AND matching
        let tokens = pattern.split(separator: " ").map(String.init).filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        // Single token - use standard matching
        if tokens.count == 1 {
            return FuzzyMatchV2.match(pattern: tokens[0], text: text, caseSensitive: caseSensitive)
        }

        // Multiple tokens - all must match (AND behavior)
        var totalScore = 0
        var allPositions: [Int] = []

        for token in tokens {
            guard let result = FuzzyMatchV2.match(pattern: token, text: text, caseSensitive: caseSensitive) else {
                // If any token doesn't match, the whole pattern doesn't match
                return nil
            }
            totalScore += result.score
            allPositions.append(contentsOf: result.positions)
        }

        // Remove duplicate positions and sort
        allPositions = Array(Set(allPositions)).sorted()

        return MatchResult(score: totalScore, positions: allPositions)
    }

    /// Match pattern against items and return sorted results
    func matchItems(pattern: String, items: [Item]) -> [MatchedItem] {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)

        guard !trimmedPattern.isEmpty else {
            // Empty pattern matches everything with score 0
            return items.map { MatchedItem(item: $0, matchResult: MatchResult(score: 0, positions: [])) }
        }

        var matched: [MatchedItem] = []
        for item in items {
            if let result = match(pattern: trimmedPattern, text: item.text) {
                matched.append(MatchedItem(item: item, matchResult: result))
            }
        }

        // Sort by score (descending)
        matched.sort { $0.matchResult.score > $1.matchResult.score }
        return matched
    }
}

/// Item with match result
struct MatchedItem: Sendable {
    let item: Item
    let matchResult: MatchResult

    var score: Int {
        matchResult.score
    }
}
