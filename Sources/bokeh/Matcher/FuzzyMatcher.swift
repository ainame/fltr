import Foundation

/// Main fuzzy matching interface
struct FuzzyMatcher: Sendable {
    let caseSensitive: Bool

    init(caseSensitive: Bool = false) {
        self.caseSensitive = caseSensitive
    }

    /// Match a pattern against text
    func match(pattern: String, text: String) -> MatchResult? {
        FuzzyMatchV2.match(pattern: pattern, text: text, caseSensitive: caseSensitive)
    }

    /// Match pattern against items and return sorted results
    func matchItems(pattern: String, items: [Item]) -> [MatchedItem] {
        guard !pattern.isEmpty else {
            // Empty pattern matches everything with score 0
            return items.map { MatchedItem(item: $0, matchResult: MatchResult(score: 0, positions: [])) }
        }

        var matched: [MatchedItem] = []
        for item in items {
            if let result = match(pattern: pattern, text: item.text) {
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
