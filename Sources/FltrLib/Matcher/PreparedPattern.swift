/// A pattern pre-processed for repeated matching. Create once per query,
/// reuse across all candidates. Analogous to FuzzyMatch's `FuzzyQuery`.
///
/// This struct eliminates redundant per-candidate work by pre-computing:
/// - Lowercased UTF-8 bytes of the pattern (for case-insensitive matching)
/// - Token ranges for space-separated AND queries
///
/// Example:
/// ```swift
/// let pattern = matcher.prepare("foo bar")
/// for item in items {
///     var buffer = matcher.makeBuffer()
///     let result = matcher.match(pattern, textBuf: item.bytes, buffer: &buffer)
/// }
/// ```
public struct PreparedPattern: Sendable {
    /// Original pattern string (kept for display and debugging)
    public let original: String

    /// Pre-lowercased UTF-8 bytes of the full pattern.
    /// Used for case-insensitive matching to avoid repeated toLower calls.
    public let lowercasedBytes: [UInt8]

    /// Pre-split tokens (for space-separated AND queries).
    /// Each token is a Range<Int> into lowercasedBytes.
    /// For "foo bar", this would be [0..<3, 4..<7] (assuming single space).
    public let tokenRanges: [Range<Int>]

    /// Whether case-sensitive matching was requested.
    public let caseSensitive: Bool

    /// Whether this is a multi-token pattern (space-separated AND query).
    public var isMultiToken: Bool { tokenRanges.count > 1 }

    /// Create a prepared pattern from a query string.
    ///
    /// - Parameters:
    ///   - pattern: The search pattern (may contain spaces for AND queries)
    ///   - caseSensitive: Whether to perform case-sensitive matching
    public init(pattern: String, caseSensitive: Bool = false) {
        self.original = pattern
        self.caseSensitive = caseSensitive

        // Pre-lowercase the entire pattern for case-insensitive matching
        let lowercased = caseSensitive ? pattern : pattern.lowercased()
        self.lowercasedBytes = Array(lowercased.utf8)

        // Split on spaces to create token ranges
        var ranges: [Range<Int>] = []
        var tokenStart: Int? = nil

        for (i, byte) in lowercasedBytes.enumerated() {
            if byte == 0x20 { // space
                if let start = tokenStart {
                    ranges.append(start..<i)
                    tokenStart = nil
                }
            } else {
                if tokenStart == nil {
                    tokenStart = i
                }
            }
        }

        // Add final token if present
        if let start = tokenStart {
            ranges.append(start..<lowercasedBytes.count)
        }

        // If no tokens found (empty or all spaces), treat entire string as one token
        self.tokenRanges = ranges.isEmpty ? [0..<lowercasedBytes.count] : ranges
    }
}
