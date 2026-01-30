import Foundation

/// FuzzyMatchV2 algorithm implementation
/// Based on fzf's algorithm - modified Smith-Waterman with scoring bonuses
struct FuzzyMatchV2: Sendable {
    // Scoring constants (from fzf)
    static let scoreMatch = 16
    static let scoreGapStart = -3
    static let scoreGapExtension = -1
    static let bonusConsecutive = 4
    static let bonusFirstCharMultiplier = 2

    /// Reusable matrix buffer to avoid repeated allocations
    /// Each task gets its own buffer via TaskLocal storage
    ///
    /// Safety: Marked @unchecked Sendable because instances are never shared across tasks.
    /// Each task creates its own buffer via TaskLocal storage, guaranteeing exclusive access.
    /// No concurrent mutation is possible since TaskLocal provides task-isolated storage.
    final class MatrixBuffer: @unchecked Sendable {
        var H: [[Int]] = []
        var lastMatch: [[Int]] = []

        func resize(patternLen: Int, textLen: Int) {
            let neededRows = patternLen + 1
            let neededCols = textLen + 1

            // Grow rows if needed
            if H.count < neededRows {
                H = Array(repeating: Array(repeating: 0, count: neededCols), count: neededRows)
                lastMatch = Array(repeating: Array(repeating: 0, count: neededCols), count: neededRows)
            } else {
                // Grow columns if needed
                if H[0].count < neededCols {
                    H = Array(repeating: Array(repeating: 0, count: neededCols), count: neededRows)
                    lastMatch = Array(repeating: Array(repeating: 0, count: neededCols), count: neededRows)
                }
            }
        }

        func clear(patternLen: Int, textLen: Int) {
            // Reset values for reuse
            for i in 0...patternLen {
                for j in 0...textLen {
                    H[i][j] = Int.min / 2
                    lastMatch[i][j] = -1
                }
            }
        }
    }

    @TaskLocal static var matrixBuffer: MatrixBuffer?

    /// Main matching function
    static func match(pattern: String, text: String, caseSensitive: Bool = false) -> MatchResult? {
        guard !pattern.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        let patternChars = caseSensitive ? Array(pattern) : Array(pattern.lowercased())
        let textChars = caseSensitive ? Array(text) : Array(text.lowercased())

        // Quick check: all pattern chars must exist in text
        guard containsAllChars(pattern: patternChars, text: textChars) else {
            return nil
        }

        // Classify characters for bonus calculation
        let charClasses = textChars.map { CharClass.classify($0) }

        let patternLen = patternChars.count
        let textLen = textChars.count

        // Get or create matrix buffer (reuses allocations across matches)
        let buffer = matrixBuffer ?? MatrixBuffer()
        buffer.resize(patternLen: patternLen, textLen: textLen)
        buffer.clear(patternLen: patternLen, textLen: textLen)

        // Initialize: empty pattern matches with score 0
        for j in 0...textLen {
            buffer.H[0][j] = 0
        }

        // Fill DP table
        for i in 1...patternLen {
            for j in 1...textLen {
                if patternChars[i - 1] == textChars[j - 1] {
                    // Character match
                    let bonus: Int
                    if j == 1 {
                        bonus = 8  // First character bonus
                    } else {
                        bonus = CharClass.bonus(current: charClasses[j - 1], previous: charClasses[j - 2])
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

    private static func containsAllChars(pattern: [Character], text: [Character]) -> Bool {
        var textIndex = 0
        for patternChar in pattern {
            while textIndex < text.count && text[textIndex] != patternChar {
                textIndex += 1
            }
            if textIndex >= text.count {
                return false
            }
            textIndex += 1
        }
        return true
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
