import Foundation
import FuzzyMatch

/// Selects which matcher backend powers fuzzy scoring.
public enum MatcherAlgorithm: Sendable, CustomStringConvertible {
    case utf8
    case swfast
    case fuzzymatch

    public static func parse(_ s: String) -> MatcherAlgorithm? {
        switch s.lowercased() {
        case "utf8":
            return .utf8
        case "swfast":
            return .swfast
        case "fuzzymatch":
            return .fuzzymatch
        default:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .utf8:
            return "utf8"
        case .swfast:
            return "swfast"
        case .fuzzymatch:
            return "fuzzymatch"
        }
    }
}

/// Per-task scratch storage for matcher backends.
/// Backends may reuse internal buffers through this object.
public final class MatcherScratch: @unchecked Sendable {
    struct QueryKey: Hashable {
        let pattern: String
        let caseSensitive: Bool
    }

    var fuzzyBuffer: FuzzyMatch.ScoringBuffer = FuzzyMatch.ScoringBuffer()
    var queryCache: [QueryKey: FuzzyMatch.FuzzyQuery] = [:]

    public init() {}
}

/// Swappable backend contract for fuzzy matching engines.
protocol MatcherBackend: Sendable {
    var algorithm: MatcherAlgorithm { get }
    func prepare(_ pattern: String, caseSensitive: Bool) -> PreparedPattern
    func makeScratch() -> MatcherScratch
    func matchRank(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> RankMatch?
    func matchHighlight(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> MatchResult?
    func match(pattern: String, text: String, caseSensitive: Bool) -> MatchResult?
    func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> MatchResult?
}

struct FuzzyMatchBackend: MatcherBackend {
    let algorithm: MatcherAlgorithm = .fuzzymatch

    // We delegate tokenization/AND semantics to Fltr's FuzzyMatcher layer.
    private let matcher = FuzzyMatch.FuzzyMatcher(
        config: FuzzyMatch.MatchConfig(minScore: 0.0, algorithm: .smithWaterman())
    )

    func prepare(_ pattern: String, caseSensitive: Bool) -> PreparedPattern {
        PreparedPattern(pattern: pattern, caseSensitive: caseSensitive)
    }

    func makeScratch() -> MatcherScratch {
        MatcherScratch()
    }

    func matchRank(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> RankMatch? {
        let query = preparedQuery(for: prepared, scratch: scratch)
        let text = String(decoding: textBuf, as: UTF8.self)
        guard let scored = matcher.score(text, against: query, buffer: &scratch.fuzzyBuffer) else {
            return nil
        }

        guard let positions = greedyMatchPositions(pattern: prepared.lowercasedBytes, textBuf: textBuf, caseSensitive: prepared.caseSensitive) else {
            return nil
        }

        let minBegin = positions.first ?? 0
        return RankMatch(score: normalizeScore(scored.score), minBegin: minBegin)
    }

    func matchHighlight(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> MatchResult? {
        let query = preparedQuery(for: prepared, scratch: scratch)
        let text = String(decoding: textBuf, as: UTF8.self)
        guard let scored = matcher.score(text, against: query, buffer: &scratch.fuzzyBuffer) else {
            return nil
        }

        guard let positions = greedyMatchPositions(pattern: prepared.lowercasedBytes, textBuf: textBuf, caseSensitive: prepared.caseSensitive) else {
            return nil
        }

        return MatchResult(score: normalizeScore(scored.score), positions: positions)
    }

    func match(pattern: String, text: String, caseSensitive: Bool) -> MatchResult? {
        let prepared = prepare(pattern, caseSensitive: caseSensitive)
        let scratch = makeScratch()
        return text.utf8.withContiguousStorageIfAvailable { ptr in
            let textBuf = UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count)
            return matchHighlight(prepared: prepared, textBuf: textBuf, scratch: scratch)
        } ?? {
            let bytes = Array(text.utf8)
            return bytes.withUnsafeBufferPointer { textBuf in
                matchHighlight(prepared: prepared, textBuf: textBuf, scratch: scratch)
            }
        }()
    }

    func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> MatchResult? {
        let prepared = prepare(pattern, caseSensitive: caseSensitive)
        let scratch = makeScratch()
        return matchHighlight(prepared: prepared, textBuf: textBuf, scratch: scratch)
    }

    private func preparedQuery(for prepared: PreparedPattern, scratch: MatcherScratch) -> FuzzyMatch.FuzzyQuery {
        let key = MatcherScratch.QueryKey(pattern: prepared.original, caseSensitive: prepared.caseSensitive)
        if let cached = scratch.queryCache[key] {
            return cached
        }
        let query = matcher.prepare(prepared.original)
        scratch.queryCache[key] = query
        return query
    }

    @inline(__always)
    private func normalizeScore(_ score: Double) -> Int16 {
        Int16(clamping: Int((score * 10_000).rounded(.toNearestOrAwayFromZero)))
    }

    @inline(__always)
    private func folded(_ b: UInt8, caseSensitive: Bool) -> UInt8 {
        if caseSensitive {
            return b
        }
        return (b >= 0x41 && b <= 0x5A) ? (b | 0x20) : b
    }

    private func greedyMatchPositions(pattern: [UInt8], textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> [UInt16]? {
        guard !pattern.isEmpty else { return [] }
        guard pattern.count <= textBuf.count else { return nil }

        var positions: [UInt16] = []
        positions.reserveCapacity(pattern.count)

        var textIndex = 0
        for pb in pattern {
            let foldedPattern = folded(pb, caseSensitive: caseSensitive)
            var found = false
            while textIndex < textBuf.count {
                let tb = textBuf[textIndex]
                if folded(tb, caseSensitive: caseSensitive) == foldedPattern {
                    positions.append(UInt16(clamping: textIndex))
                    textIndex += 1
                    found = true
                    break
                }
                textIndex += 1
            }
            if !found {
                return nil
            }
        }

        return positions
    }
}

/// Backward-compatible algorithm alias.
/// `utf8` now routes through the upstream FuzzyMatch kernel.
struct Utf8MatcherBackend: MatcherBackend {
    let algorithm: MatcherAlgorithm = .utf8
    private let delegate = FuzzyMatchBackend()

    func prepare(_ pattern: String, caseSensitive: Bool) -> PreparedPattern {
        delegate.prepare(pattern, caseSensitive: caseSensitive)
    }

    func makeScratch() -> MatcherScratch {
        delegate.makeScratch()
    }

    func matchRank(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> RankMatch? {
        delegate.matchRank(prepared: prepared, textBuf: textBuf, scratch: scratch)
    }

    func matchHighlight(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> MatchResult? {
        delegate.matchHighlight(prepared: prepared, textBuf: textBuf, scratch: scratch)
    }

    func match(pattern: String, text: String, caseSensitive: Bool) -> MatchResult? {
        delegate.match(pattern: pattern, text: text, caseSensitive: caseSensitive)
    }

    func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> MatchResult? {
        delegate.match(pattern: pattern, textBuf: textBuf, caseSensitive: caseSensitive)
    }
}

/// Backward-compatible algorithm alias.
/// `swfast` routes through the upstream FuzzyMatch kernel with a quick bitmask prefilter.
struct SwFastMatcherBackend: MatcherBackend {
    let algorithm: MatcherAlgorithm = .swfast
    private let delegate = FuzzyMatchBackend()

    func prepare(_ pattern: String, caseSensitive: Bool) -> PreparedPattern {
        delegate.prepare(pattern, caseSensitive: caseSensitive)
    }

    func makeScratch() -> MatcherScratch {
        delegate.makeScratch()
    }

    func matchRank(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> RankMatch? {
        let textMask = foldedMask(textBuf, caseSensitive: prepared.caseSensitive)
        if (prepared.foldedByteMask & ~textMask) != 0 {
            return nil
        }
        return delegate.matchRank(prepared: prepared, textBuf: textBuf, scratch: scratch)
    }

    func matchHighlight(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> MatchResult? {
        let textMask = foldedMask(textBuf, caseSensitive: prepared.caseSensitive)
        if (prepared.foldedByteMask & ~textMask) != 0 {
            return nil
        }
        return delegate.matchHighlight(prepared: prepared, textBuf: textBuf, scratch: scratch)
    }

    func match(pattern: String, text: String, caseSensitive: Bool) -> MatchResult? {
        delegate.match(pattern: pattern, text: text, caseSensitive: caseSensitive)
    }

    func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> MatchResult? {
        delegate.match(pattern: pattern, textBuf: textBuf, caseSensitive: caseSensitive)
    }

    @inline(__always)
    private func foldedMask(_ textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> UInt64 {
        var mask: UInt64 = 0
        if caseSensitive {
            for b in textBuf {
                mask |= (UInt64(1) << UInt64(b & 63))
            }
            return mask
        }

        for b in textBuf {
            let lb: UInt8 = (b >= 0x41 && b <= 0x5A) ? (b | 0x20) : b
            mask |= (UInt64(1) << UInt64(lb & 63))
        }
        return mask
    }
}
