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

        // DP matrices: H[i][j] = best score ending at text[j] with pattern[i]
        var H = Array(repeating: Array(repeating: Int.min / 2, count: textLen + 1), count: patternLen + 1)
        var lastMatch = Array(repeating: Array(repeating: -1, count: textLen + 1), count: patternLen + 1)

        // Initialize: empty pattern matches with score 0
        for j in 0...textLen {
            H[0][j] = 0
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
                    let consecutiveBonus = (lastMatch[i - 1][j - 1] == j - 2) ? bonusConsecutive : 0

                    let matchScore = H[i - 1][j - 1] + scoreMatch + bonus + consecutiveBonus
                    H[i][j] = matchScore
                    lastMatch[i][j] = j - 1
                } else {
                    // Gap: carry forward best score from left
                    H[i][j] = H[i][j - 1] + scoreGapExtension
                    lastMatch[i][j] = lastMatch[i][j - 1]
                }
            }
        }

        // Find best score in last row
        var bestScore = Int.min
        var bestCol = -1
        for j in patternLen...textLen {
            if H[patternLen][j] > bestScore {
                bestScore = H[patternLen][j]
                bestCol = j
            }
        }

        guard bestScore > Int.min / 2 else {
            return nil
        }

        // Backtrack to find match positions
        let positions = backtrack(H: H, lastMatch: lastMatch, patternLen: patternLen, endCol: bestCol)

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
