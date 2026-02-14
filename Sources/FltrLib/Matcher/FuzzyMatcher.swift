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

    /// Prepare a pattern for repeated matching. Create once per query, reuse across all candidates.
    /// This is the recommended API for matching against many candidates.
    ///
    /// Example:
    /// ```swift
    /// let prepared = matcher.prepare("foo bar")
    /// var buffer = matcher.makeBuffer()
    /// for item in items {
    ///     let result = matcher.match(prepared, textBuf: item.bytes, buffer: &buffer)
    /// }
    /// ```
    func prepare(_ pattern: String) -> PreparedPattern {
        PreparedPattern(pattern: pattern, caseSensitive: caseSensitive)
    }

    /// Create a scoring buffer. Call once per thread/task.
    func makeBuffer() -> Utf8FuzzyMatch.ScoringBuffer {
        Utf8FuzzyMatch.makeBuffer()
    }

    /// High-performance match using prepared pattern and explicit buffer.
    /// Handles multi-token (space-separated AND) matching.
    ///
    /// - Parameters:
    ///   - prepared: Pre-processed pattern (created once per query)
    ///   - textBuf: Pre-sliced view into a TextBuffer
    ///   - buffer: Reusable scoring buffer (one per thread/task)
    /// - Returns: Match result or nil if no match
    func match(
        _ prepared: PreparedPattern,
        textBuf: UnsafeBufferPointer<UInt8>,
        buffer: inout Utf8FuzzyMatch.ScoringBuffer
    ) -> MatchResult? {
        guard !prepared.lowercasedBytes.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        // Single token: direct match
        if !prepared.isMultiToken {
            return Utf8FuzzyMatch.match(prepared: prepared, textBuf: textBuf, buffer: &buffer)
        }

        // Multi-token: match each token (all must match for AND behavior)
        var totalScore: Int16 = 0
        var allPositions: [UInt16] = []

        for tokenRange in prepared.tokenRanges {
            // Create a temporary PreparedPattern for this token
            // (already lowercased, so we can reuse the pre-processed bytes)
            let tokenBytes = Array(prepared.lowercasedBytes[tokenRange])
            let tokenPrepared = PreparedPattern(
                pattern: String(decoding: tokenBytes, as: UTF8.self),
                caseSensitive: prepared.caseSensitive
            )

            // Match using the prepared API
            guard let result = Utf8FuzzyMatch.match(
                prepared: tokenPrepared,
                textBuf: textBuf,
                buffer: &buffer
            ) else {
                return nil
            }
            totalScore += result.score
            allPositions.append(contentsOf: result.positions)
        }

        guard !allPositions.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        // Sort and deduplicate in-place
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

        return MatchResult(score: totalScore, positions: allPositions)
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
        var totalScore: Int16 = 0
        var allPositions: [UInt16] = []

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
    /// Multi-token (space-separated AND) is supported; tokens are extracted as
    /// ``Span<UInt8>`` slices of the pattern's UTF-8 — no ``String`` per token.
    func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>) -> MatchResult? {
        guard !pattern.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        let patSpan = pattern.utf8.span

        // Fast path: no space → single token, skip the walk entirely.
        var hasSpace = false
        for i in 0..<patSpan.count { if patSpan[i] == 0x20 { hasSpace = true; break } }
        guard hasSpace else {
            return Utf8FuzzyMatch.match(patternSpan: patSpan, textBuf: textBuf, caseSensitive: caseSensitive)
        }

        // Multi-token: walk the span once, slicing on spaces.
        var totalScore: Int16 = 0
        var allPositions: [UInt16] = []
        var tokenStart = 0

        for i in 0...patSpan.count {   // iterate one past end to flush last token
            let isEnd = (i == patSpan.count)
            if isEnd || patSpan[i] == 0x20 {
                if i > tokenStart {   // skip runs of spaces
                    let tokenSpan = patSpan.extracting(tokenStart..<i)
                    guard let result = Utf8FuzzyMatch.match(patternSpan: tokenSpan, textBuf: textBuf, caseSensitive: caseSensitive) else {
                        return nil
                    }
                    totalScore += result.score
                    allPositions.append(contentsOf: result.positions)
                }
                tokenStart = i + 1
            }
        }

        guard !allPositions.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        // Sort and deduplicate in-place
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

        return MatchResult(score: totalScore, positions: allPositions)
    }

}

/// Item with match result and precomputed ranking points.
///
/// Points are packed into a single UInt64 (lower-is-better) so that the
/// entire rank key compares with a single ``<``.  Bit layout (MSB → LSB):
///   bits 48…63  byScore      (MaxUInt16 − score)                   always active
///   bits 32…47  byPathname   (segment-local distance)              path scheme only; 0 otherwise
///   bits 16…31  byLength     (UTF-8 byte length)                   default & path; 0 for history
///   bits  0…15  unused (0)
struct MatchedItem: Sendable {
    let item: Item
    let matchResult: MatchResult
    /// Precomputed rank key.  Compare with `rankLessThan(_:_:)`.
    let points: UInt64

    /// Hot-path init: *allBytes* is the live ``TextBuffer`` pointer (held by the
    /// caller's ``withBytes`` scope).  No ``String`` allocation.
    init(item: Item, matchResult: MatchResult, scheme: SortScheme = .path, allBytes: UnsafeBufferPointer<UInt8>) {
        self.item = item
        self.matchResult = matchResult
        self.points = MatchedItem.buildPoints(
            offset: Int(item.offset), length: Int(item.length),
            matchResult: matchResult, scheme: scheme, allBytes: allBytes)
    }

    /// Fast init with pre-computed points — used by the chunkBacked zero-alloc
    /// path where score is 0, positions are empty, and byPathname is irrelevant.
    init(item: Item, matchResult: MatchResult, points: UInt64) {
        self.item = item
        self.matchResult = matchResult
        self.points = points
    }

    /// Pack four UInt16 rank slots into a single UInt64.  Argument order
    /// matches the old tuple layout: (unused, byLength, byPathname, byScore).
    @inlinable
    static func packPoints(_ s0: UInt16, _ s1: UInt16, _ s2: UInt16, _ s3: UInt16) -> UInt64 {
        UInt64(s3) << 48 | UInt64(s2) << 32 | UInt64(s1) << 16 | UInt64(s0)
    }

    var score: Int {
        Int(matchResult.score)
    }

    // MARK: - Rank-point construction  (mirrors fzf result.go : buildResult)

    /// Zero-copy buildPoints: works directly on the raw byte buffer.
    @inlinable
    static func buildPoints(
        offset: Int, length: Int,
        matchResult: MatchResult, scheme: SortScheme,
        allBytes: UnsafeBufferPointer<UInt8>
    ) -> UInt64 {
        let maxU16 = Int(UInt16.max)

        // --- byScore (bits 48…63) ---  higher score → lower value  (always active)
        let byScore = UInt16(clamping: maxU16 - Int(matchResult.score))

        // --- byPathname (bits 32…47) ---  path scheme only
        // Find the last path separator at or before the match start.
        // a match right after a '/' (distance 1) ranks above one mid-segment.
        let byPathname: UInt16
        if case .path = scheme {
            let minBegin = Int(matchResult.positions.first ?? 0)
            var delimBeforeMatch = -1
            let base = allBytes.baseAddress! + offset
            for idx in 0..<min(minBegin, length) {
                let ch = base[idx]
                if ch == 0x2F || ch == 0x5C {   // '/' or '\'
                    delimBeforeMatch = idx
                }
            }
            byPathname = UInt16(clamping: minBegin - delimBeforeMatch)
        } else {
            byPathname = 0
        }

        // --- byLength (bits 16…31) ---  default & path schemes only
        let byLength: UInt16
        if case .history = scheme {
            byLength = 0
        } else {
            byLength = UInt16(clamping: length)
        }

        return packPoints(0, byLength, byPathname, byScore)
    }
}

/// Compare two MatchedItems by their packed rank key.
/// Single UInt64 comparison covers all four priority levels;
/// ties broken by original insertion order (item.index ascending).
func rankLessThan(_ a: MatchedItem, _ b: MatchedItem) -> Bool {
    a.points != b.points ? a.points < b.points : a.item.index < b.item.index
}
