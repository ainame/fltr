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
        // Split pattern by whitespace for AND matching (optimized to avoid intermediate allocations)
        let tokens = pattern.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        guard !tokens.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        // Single token - use standard matching
        if tokens.count == 1 {
            return Utf8FuzzyMatch.match(pattern: tokens[0], text: text, caseSensitive: caseSensitive)
        }

        // Multiple tokens - all must match (AND behavior)
        var totalScore = 0
        var allPositions: [Int] = []

        for token in tokens {
            guard let result = Utf8FuzzyMatch.match(pattern: token, text: text, caseSensitive: caseSensitive) else {
                // If any token doesn't match, the whole pattern doesn't match
                return nil
            }
            totalScore += result.score
            allPositions.append(contentsOf: result.positions)
        }

        // Remove duplicate positions and sort (optimized: sort then deduplicate in-place)
        if !allPositions.isEmpty {
            allPositions.sort()
            var writeIndex = 1
            for readIndex in 1..<allPositions.count {
                if allPositions[readIndex] != allPositions[readIndex - 1] {
                    if writeIndex != readIndex {
                        allPositions[writeIndex] = allPositions[readIndex]
                    }
                    writeIndex += 1
                }
            }
            allPositions.removeLast(allPositions.count - writeIndex)
        }

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

        matched.sort(by: rankLessThan)
        return matched
    }
}

/// Item with match result and precomputed ranking points.
///
/// Ranking mirrors fzf's "path" scheme: `[byScore, byPathname, byLength]`.
/// Points are packed into four UInt16 slots stored lower-is-better; the
/// comparison walks from index 3 (highest priority) down to 0.
///   points[3] = byScore      (MaxUInt16 − score)
///   points[2] = byPathname   (distance from match-start to last path separator;
///                              MaxUInt16 when match crosses the separator)
///   points[1] = byLength     (trimmed item length)
///   points[0] = unused (0)
struct MatchedItem: Sendable {
    let item: Item
    let matchResult: MatchResult
    /// Precomputed rank key.  Compare with `rankLessThan(_:_:)`.
    let points: (UInt16, UInt16, UInt16, UInt16)   // [0] … [3]

    init(item: Item, matchResult: MatchResult) {
        self.item = item
        self.matchResult = matchResult
        self.points = MatchedItem.buildPoints(text: item.text, matchResult: matchResult)
    }

    var score: Int {
        matchResult.score
    }

    // MARK: - Rank-point construction  (mirrors fzf result.go : buildResult)

    private static func buildPoints(text: String, matchResult: MatchResult) -> (UInt16, UInt16, UInt16, UInt16) {
        let maxU16 = Int(UInt16.max)

        // --- byScore (points[3]) ---  higher score → lower value
        let byScore = UInt16(clamping: maxU16 - matchResult.score)

        // --- byPathname (points[2]) ---
        // Find the last path separator at or before the match start.
        // This measures how far into its own path segment the match begins —
        // a match right after a '/' (distance 1) ranks above one mid-segment.
        // Using the separator immediately before minBegin (rather than the last
        // separator in the whole string) keeps directory-children like
        // "../renovate/lib" on equal footing with "../renovate-wrapper" when
        // both match "renovate" right after a '/'.
        let minBegin = matchResult.positions.first ?? 0
        var delimBeforeMatch = -1
        var idx = 0
        for ch in text.utf8 {
            if idx >= minBegin { break }
            if ch == 0x2F || ch == 0x5C {   // '/' or '\'
                delimBeforeMatch = idx
            }
            idx += 1
        }
        let byPathname = UInt16(clamping: minBegin - delimBeforeMatch)

        // --- byLength (points[1]) ---  shorter items rank higher
        // fzf uses TrimLength (trailing whitespace stripped).  We approximate
        // with the full UTF-8 byte length; trimming whitespace here would cost
        // an allocation on every item.
        let byLength = UInt16(clamping: text.utf8.count)

        return (0, byLength, byPathname, byScore)
    }
}

/// Compare two MatchedItems by their rank points.
/// Returns true when `a` should sort before `b` (i.e. `a` is more relevant).
/// Walks points[3]…points[0]; lower value wins at each level.
/// Ties broken by original insertion order (item.index ascending).
func rankLessThan(_ a: MatchedItem, _ b: MatchedItem) -> Bool {
    if a.points.3 != b.points.3 { return a.points.3 < b.points.3 }
    if a.points.2 != b.points.2 { return a.points.2 < b.points.2 }
    if a.points.1 != b.points.1 { return a.points.1 < b.points.1 }
    if a.points.0 != b.points.0 { return a.points.0 < b.points.0 }
    return a.item.index < b.item.index
}
