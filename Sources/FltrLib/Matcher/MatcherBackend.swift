import Foundation

/// Selects which matcher backend powers fuzzy scoring.
public enum MatcherAlgorithm: Sendable, CustomStringConvertible {
    case utf8
    case swfast

    public static func parse(_ s: String) -> MatcherAlgorithm? {
        switch s.lowercased() {
        case "utf8":
            return .utf8
        case "swfast":
            return .swfast
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
        }
    }
}

/// Per-task scratch storage for matcher backends.
/// Backends may reuse internal buffers through this object.
public final class MatcherScratch: @unchecked Sendable {
    var utf8Buffer: Utf8FuzzyMatch.ScoringBuffer = Utf8FuzzyMatch.makeBuffer()

    public init() {}
}

/// Swappable backend contract for fuzzy matching engines.
protocol MatcherBackend: Sendable {
    var algorithm: MatcherAlgorithm { get }
    func prepare(_ pattern: String, caseSensitive: Bool) -> PreparedPattern
    func makeScratch() -> MatcherScratch
    func match(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> MatchResult?
    func match(pattern: String, text: String, caseSensitive: Bool) -> MatchResult?
    func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> MatchResult?
}

struct Utf8MatcherBackend: MatcherBackend {
    let algorithm: MatcherAlgorithm = .utf8

    func prepare(_ pattern: String, caseSensitive: Bool) -> PreparedPattern {
        PreparedPattern(pattern: pattern, caseSensitive: caseSensitive)
    }

    func makeScratch() -> MatcherScratch {
        MatcherScratch()
    }

    func match(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> MatchResult? {
        Utf8FuzzyMatch.match(prepared: prepared, textBuf: textBuf, buffer: &scratch.utf8Buffer)
    }

    func match(pattern: String, text: String, caseSensitive: Bool) -> MatchResult? {
        Utf8FuzzyMatch.match(pattern: pattern, text: text, caseSensitive: caseSensitive)
    }

    func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> MatchResult? {
        Utf8FuzzyMatch.match(pattern: pattern, textBuf: textBuf, caseSensitive: caseSensitive)
    }
}

/// SW-fast backend scaffold.
/// Current implementation intentionally delegates to Utf8 backend so we can
/// wire backend swap safely before introducing a new kernel.
struct SwFastMatcherBackend: MatcherBackend {
    let algorithm: MatcherAlgorithm = .swfast
    private let delegate = Utf8MatcherBackend()

    func prepare(_ pattern: String, caseSensitive: Bool) -> PreparedPattern {
        delegate.prepare(pattern, caseSensitive: caseSensitive)
    }

    func makeScratch() -> MatcherScratch {
        delegate.makeScratch()
    }

    func match(prepared: PreparedPattern, textBuf: UnsafeBufferPointer<UInt8>, scratch: MatcherScratch) -> MatchResult? {
        // Fast negative prefilter: if a required folded-byte bit from the query
        // is missing in candidate text, we can reject before DP.
        let textMask = foldedMask(textBuf, caseSensitive: prepared.caseSensitive)
        if (prepared.foldedByteMask & ~textMask) != 0 {
            return nil
        }
        return delegate.match(prepared: prepared, textBuf: textBuf, scratch: scratch)
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
            // ASCII-only lowercase fold (same approach as Utf8FuzzyMatch hot path).
            let lb: UInt8 = (b >= 0x41 && b <= 0x5A) ? (b | 0x20) : b
            mask |= (UInt64(1) << UInt64(lb & 63))
        }
        return mask
    }
}
