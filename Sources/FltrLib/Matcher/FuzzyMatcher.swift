import Foundation

/// Ranking scheme — mirrors fzf's `--scheme` option.
/// Controls which tiebreakers are active after byScore.
///   default  → [byScore, byLength]
///   path     → [byScore, byPathname, byLength]
///   history  → [byScore]          (no tiebreakers)
public enum SortScheme: Sendable {
    case `default`   // byScore, byLength
    case path        // byScore, byPathname, byLength
    case history     // byScore only

    /// Parse a user-supplied string, case-insensitive.  Returns nil on
    /// unrecognised input so the caller can emit a usage error.
    public static func parse(_ s: String) -> SortScheme? {
        switch s.lowercased() {
        case "default": return .default
        case "path":    return .path
        case "history": return .history
        default:        return nil
        }
    }
}

/// Main fuzzy matching interface
struct FuzzyMatcher: Sendable {
    let caseSensitive: Bool
    let scheme: SortScheme

    init(caseSensitive: Bool = false, scheme: SortScheme = .path) {
        self.caseSensitive = caseSensitive
        self.scheme = scheme
    }

    /// Match a pattern against text
    /// Supports space-separated tokens as AND operator (all tokens must match)
    func match(pattern: String, text: String) -> MatchResult? {
        guard !pattern.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        // Fast path: no space → single token, skip split entirely
        guard pattern.utf8.contains(0x20) else {
            return Utf8FuzzyMatch.match(pattern: pattern, text: text, caseSensitive: caseSensitive)
        }

        // Multi-token: split and AND-match
        let tokens = pattern.split(separator: " ", omittingEmptySubsequences: true)
        guard !tokens.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }
        if tokens.count == 1 {
            return Utf8FuzzyMatch.match(pattern: String(tokens[0]), text: text, caseSensitive: caseSensitive)
        }

        // Multiple tokens - all must match (AND behavior)
        var totalScore = 0
        var allPositions: [Int] = []

        for token in tokens {
            guard let result = Utf8FuzzyMatch.match(pattern: String(token), text: text, caseSensitive: caseSensitive) else {
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

    /// Zero-copy overload: *textBuf* is a pre-sliced ``UnsafeBufferPointer``
    /// into a ``TextBuffer``.  Avoids constructing a ``String`` on the hot path.
    /// Multi-token (space-separated AND) is supported; each token calls the
    /// ``textBuf`` overload of ``Utf8FuzzyMatch``.
    func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>) -> MatchResult? {
        guard !pattern.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        guard pattern.utf8.contains(0x20) else {
            return Utf8FuzzyMatch.match(pattern: pattern, textBuf: textBuf, caseSensitive: caseSensitive)
        }

        let tokens = pattern.split(separator: " ", omittingEmptySubsequences: true)
        guard !tokens.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }
        if tokens.count == 1 {
            return Utf8FuzzyMatch.match(pattern: String(tokens[0]), textBuf: textBuf, caseSensitive: caseSensitive)
        }

        var totalScore = 0
        var allPositions: [Int] = []

        for token in tokens {
            guard let result = Utf8FuzzyMatch.match(pattern: String(token), textBuf: textBuf, caseSensitive: caseSensitive) else {
                return nil
            }
            totalScore += result.score
            allPositions.append(contentsOf: result.positions)
        }

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

}

/// Item with match result and precomputed ranking points.
///
/// Points are packed into four UInt16 slots (lower-is-better); the
/// comparison walks from index 3 (highest priority) down to 0.
///   points[3] = byScore      (MaxUInt16 − score)                   always active
///   points[2] = byPathname   (segment-local distance)              path scheme only; 0 otherwise
///   points[1] = byLength     (UTF-8 byte length)                   default & path; 0 for history
///   points[0] = unused (0)
struct MatchedItem: Sendable {
    let item: Item
    let matchResult: MatchResult
    /// Precomputed rank key.  Compare with `rankLessThan(_:_:)`.
    let points: (UInt16, UInt16, UInt16, UInt16)   // [0] … [3]

    init(item: Item, matchResult: MatchResult, scheme: SortScheme = .path) {
        self.item = item
        self.matchResult = matchResult
        self.points = MatchedItem.buildPoints(text: item.text, matchResult: matchResult, scheme: scheme)
    }

    var score: Int {
        matchResult.score
    }

    // MARK: - Rank-point construction  (mirrors fzf result.go : buildResult)

    private static func buildPoints(text: String, matchResult: MatchResult, scheme: SortScheme) -> (UInt16, UInt16, UInt16, UInt16) {
        let maxU16 = Int(UInt16.max)

        // --- byScore (points[3]) ---  higher score → lower value  (always active)
        let byScore = UInt16(clamping: maxU16 - matchResult.score)

        // --- byPathname (points[2]) ---  path scheme only
        // Find the last path separator at or before the match start.
        // This measures how far into its own path segment the match begins —
        // a match right after a '/' (distance 1) ranks above one mid-segment.
        // Using the separator immediately before minBegin (rather than the last
        // separator in the whole string) keeps directory-children like
        // "../renovate/lib" on equal footing with "../renovate-wrapper" when
        // both match "renovate" right after a '/'.
        let byPathname: UInt16
        if case .path = scheme {
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
            byPathname = UInt16(clamping: minBegin - delimBeforeMatch)
        } else {
            byPathname = 0
        }

        // --- byLength (points[1]) ---  default & path schemes only
        // fzf uses TrimLength (trailing whitespace stripped).  We approximate
        // with the full UTF-8 byte length; trimming whitespace here would cost
        // an allocation on every item.
        let byLength: UInt16
        if case .history = scheme {
            byLength = 0
        } else {
            byLength = UInt16(clamping: text.utf8.count)
        }

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
