import Foundation

/// Optimized fuzzy matching using UTF-8 byte-level operations
/// This version uses String.utf8.span for zero-copy access to avoid Character array allocations
public struct Utf8FuzzyMatch: Sendable {
    // Scoring constants (from fzf)
    static let scoreMatch = 16
    static let scoreGapStart = -3
    static let scoreGapExtension = -1
    static let bonusConsecutive = 4
    static let bonusFirstCharMultiplier = 2

    /// Reusable matrix buffer to avoid repeated allocations
    final class MatrixBuffer: @unchecked Sendable {
        var H: [[Int]] = []
        var lastMatch: [[Int]] = []

        func resize(patternLen: Int, textLen: Int) {
            let neededRows = patternLen + 1
            let neededCols = textLen + 1

            if H.count < neededRows || H[0].count < neededCols {
                H = Array(repeating: Array(repeating: 0, count: neededCols), count: neededRows)
                lastMatch = Array(repeating: Array(repeating: 0, count: neededCols), count: neededRows)
            }
        }

        func clear(patternLen: Int, textLen: Int) {
            for i in 0...patternLen {
                for j in 0...textLen {
                    H[i][j] = Int.min / 2
                    lastMatch[i][j] = -1
                }
            }
        }
    }

    @TaskLocal static var matrixBuffer: MatrixBuffer?

    /// Byte-level character classification
    @inlinable
    static func classify(_ byte: UInt8) -> CharClass {
        switch byte {
        case 0x09, 0x0A, 0x0D, 0x20:  // \t, \n, \r, space
            return .whitespace
        case 0x5F, 0x2D, 0x2F, 0x5C, 0x2E, 0x3A:  // _ - / \ . :
            return .delimiter
        case 0x30...0x39:  // 0-9
            return .number
        case 0x41...0x5A:  // A-Z
            return .upper
        case 0x61...0x7A:  // a-z
            return .lower
        default:
            // Non-ASCII or other - treat as letter
            return .letter
        }
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
        default:
            return 0
        }
    }

    /// Fast ASCII lowercase
    @inlinable
    static func toLower(_ byte: UInt8) -> UInt8 {
        if byte >= 0x41 && byte <= 0x5A {  // A-Z
            return byte + 0x20  // Convert to a-z
        }
        return byte
    }

    /// Optimized pre-filter using UTF-8 bytes
    @inlinable
    static func containsAllBytes(pattern: Span<UInt8>, text: Span<UInt8>, caseSensitive: Bool) -> Bool {
        guard pattern.count <= text.count else { return false }

        var textIndex = 0
        for i in 0..<pattern.count {
            let patternByte = caseSensitive ? pattern[i] : toLower(pattern[i])

            while textIndex < text.count {
                let textByte = caseSensitive ? text[textIndex] : toLower(text[textIndex])
                if patternByte == textByte {
                    break
                }
                textIndex += 1
            }

            if textIndex >= text.count {
                return false
            }
            textIndex += 1
        }
        return true
    }

    /// Main matching function using UTF-8 byte-level operations
    public static func match(pattern: String, text: String, caseSensitive: Bool = false) -> MatchResult? {
        guard !pattern.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        // Use utf8.span for zero-copy access
        let patternSpan = pattern.utf8.span
        let textSpan = text.utf8.span

        // Quick check using byte-level scan
        guard containsAllBytes(pattern: patternSpan, text: textSpan, caseSensitive: caseSensitive) else {
            return nil
        }

        let patternLen = patternSpan.count
        let textLen = textSpan.count

        // Classify characters for bonus calculation
        var charClasses = [CharClass](repeating: .letter, count: textLen)
        for i in 0..<textLen {
            charClasses[i] = classify(textSpan[i])
        }

        // Use buffer reuse for better performance in parallel contexts
        let buffer = matrixBuffer ?? MatrixBuffer()
        buffer.resize(patternLen: patternLen, textLen: textLen)
        buffer.clear(patternLen: patternLen, textLen: textLen)

        // Initialize: empty pattern matches with score 0
        for j in 0...textLen {
            buffer.H[0][j] = 0
        }

        // Fill DP table using byte-level comparisons
        for i in 1...patternLen {
            let patternByte = caseSensitive ? patternSpan[i - 1] : toLower(patternSpan[i - 1])

            for j in 1...textLen {
                let textByte = caseSensitive ? textSpan[j - 1] : toLower(textSpan[j - 1])

                if patternByte == textByte {
                    // Character match
                    let bonus: Int
                    if j == 1 {
                        bonus = 8  // First character bonus
                    } else {
                        bonus = Self.bonus(current: charClasses[j - 1], previous: charClasses[j - 2])
                    }

                    // Check for consecutive match
                    let consecutiveBonus = (buffer.lastMatch[i - 1][j - 1] == j - 2) ? bonusConsecutive : 0

                    let matchScore = buffer.H[i - 1][j - 1] + scoreMatch + bonus + consecutiveBonus
                    buffer.H[i][j] = matchScore
                    buffer.lastMatch[i][j] = j - 1
                } else {
                    // Gap: carry forward best score from left
                    buffer.H[i][j] = buffer.H[i][j - 1] + scoreGapExtension
                    buffer.lastMatch[i][j] = buffer.lastMatch[i][j - 1]
                }
            }
        }

        // Find best score in last row
        var bestScore = Int.min
        var bestCol = -1
        for j in patternLen...textLen {
            if buffer.H[patternLen][j] > bestScore {
                bestScore = buffer.H[patternLen][j]
                bestCol = j
            }
        }

        guard bestScore > Int.min / 2 else {
            return nil
        }

        // Backtrack to find match positions
        let positions = backtrack(H: buffer.H, lastMatch: buffer.lastMatch, patternLen: patternLen, endCol: bestCol)

        return MatchResult(score: bestScore, positions: positions)
    }

    private static func backtrack(H: [[Int]], lastMatch: [[Int]], patternLen: Int, endCol: Int) -> [Int] {
        var positions: [Int] = []
        var col = endCol
        var row = patternLen

        while row > 0 && col > 0 {
            let matchPos = lastMatch[row][col]
            if matchPos >= 0 && matchPos < col {
                positions.append(matchPos)
                row -= 1
                col = matchPos
            } else {
                col -= 1
            }
        }

        return positions.reversed()
    }
}
