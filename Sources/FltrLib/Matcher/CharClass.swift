import Foundation

/// Character classification for bonus scoring
/// Based on fzf's character classification system
public enum CharClass: Sendable {
    case whitespace
    case delimiter
    case lower
    case upper
    case letter
    case number

    /// Stable integer index for bonus-table lookups.  Order must match
    /// the initialiser in Utf8FuzzyMatch.bonusTable.
    @inlinable
    var index: Int {
        switch self {
        case .whitespace: return 0
        case .delimiter:  return 1
        case .lower:      return 2
        case .upper:      return 3
        case .letter:     return 4
        case .number:     return 5
        }
    }

    // Static delimiter set to avoid repeated allocations
    @usableFromInline
    internal static let delimiters: Set<Character> = ["_", "-", "/", "\\", ".", ":", " ", "\t"]

    @inlinable
    static func classify(_ char: Character) -> CharClass {
        if char.isWhitespace {
            return .whitespace
        }

        if delimiters.contains(char) {
            return .delimiter
        }

        if char.isNumber {
            return .number
        }

        if char.isLetter {
            if char.isUppercase {
                return .upper
            } else if char.isLowercase {
                return .lower
            }
            return .letter
        }

        return .letter
    }

    /// Calculate bonus for matching at this position
    @inlinable
    static func bonus(current: CharClass, previous: CharClass) -> Int {
        switch (current, previous) {
        case (_, .whitespace):
            return 8  // bonusBoundary - after whitespace
        case (_, .delimiter):
            return 7  // bonusBoundary - 1 - after delimiter
        case (.upper, .lower):
            return 7  // camelCase transition
        case (.lower, .upper):
            return 6  // after uppercase (but we're lowercase)
        case (_, _) where previous == .delimiter:
            return 6
        default:
            return 0
        }
    }
}
