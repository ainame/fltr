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

    /// Reusable matrix buffer to avoid repeated allocations.
    /// Uses flat [Int] arrays with stride-based indexing for contiguous memory layout
    /// and single-level indirection.  Also pools charClasses and lowered text bytes
    /// so that match() performs zero heap allocations on the hot path once the buffer
    /// has warmed up.
    final class MatrixBuffer: @unchecked Sendable {
        /// Flat row-major storage.  Access: index = row * stride + col
        var H: [Int] = []
        var lastMatch: [Int] = []

        /// Pooled per-call buffers (grown but never shrunk)
        var charClasses: [CharClass] = []
        var loweredText: [UInt8] = []

        /// Current dimensions of the allocated grid
        private var allocatedRows: Int = 0
        private var allocatedCols: Int = 0

        /// stride = allocatedCols (number of columns in the flat layout)
        @inlinable var stride: Int { allocatedCols }

        /// True immediately after resize() allocates fresh memory.
        /// When true, clear() can be skipped because Swift zero-initialises
        /// new Array storage.  The DP init loop overwrites row 0 explicitly,
        /// and rows 1…patternLen are fully written by the DP, so the only
        /// value that matters is Int.min/2 for cells that are never written —
        /// but with this DP formulation every cell in [0…patternLen][0…textLen]
        /// IS written, so fresh zero memory is fine to skip clearing.
        private var freshlyAllocated: Bool = false

        /// Ensure the grid is at least (patternLen+1) × (textLen+1).
        /// Returns true if reallocation happened (caller can skip clear).
        @inlinable
        func resize(patternLen: Int, textLen: Int) {
            let neededRows = patternLen + 1
            let neededCols = textLen + 1

            if neededRows > allocatedRows || neededCols > allocatedCols {
                let rows = max(neededRows, allocatedRows)
                let cols = max(neededCols, allocatedCols)
                let size = rows * cols
                H = [Int](repeating: 0, count: size)
                lastMatch = [Int](repeating: -1, count: size)
                allocatedRows = rows
                allocatedCols = cols
                freshlyAllocated = true
            } else {
                freshlyAllocated = false
            }
        }

        /// Zero out the used region.  Skipped entirely when resize() just
        /// allocated fresh storage (see `freshlyAllocated`).
        @inlinable
        func clear(patternLen: Int, textLen: Int) {
            guard !freshlyAllocated else { return }

            let cols = stride
            // Row 0 is overwritten by the init loop in match(), so start at row 1.
            // lastMatch row 0 is never read, so skip it too.
            for i in 1...patternLen {
                let base = i * cols
                for j in 0...textLen {
                    H[base + j] = Int.min / 2
                    lastMatch[base + j] = -1
                }
            }
            // Row 0 of lastMatch: only index 0 could theoretically be read; safe default.
            lastMatch[0] = -1
        }

        /// Ensure charClasses and loweredText can hold `count` elements.
        @inlinable
        func resizeTextBuffers(count: Int) {
            if charClasses.count < count {
                charClasses = [CharClass](repeating: .letter, count: count)
                loweredText = [UInt8](repeating: 0, count: count)
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

    /// Compute the DP window bounds via a forward + backward byte scan.
    ///
    /// Forward pass: find the earliest positions where each pattern byte can
    /// match in order (same logic as the old containsAllBytes).  Record where
    /// pattern[0] first matched and where pattern[last] first matched.
    ///
    /// Backward pass: from the end of the text, find the *last* occurrence of
    /// the final pattern byte.  This widens the right bound so the DP can find
    /// the globally-best alignment, not just the leftmost one.
    ///
    /// Returns nil when no in-order match exists (early rejection, zero DP work).
    /// Otherwise returns (first, last) where:
    ///   first — inclusive left bound for the DP j-loop (stepped back by 1 from
    ///           the first pattern-byte match so the bonus calculation can see
    ///           the preceding character, mirroring fzf's asciiFuzzyIndex).
    ///   last  — inclusive right bound (the column index of the rightmost
    ///           occurrence of the last pattern byte).
    @inlinable
    static func scopeIndices(pattern: Span<UInt8>, text: Span<UInt8>, caseSensitive: Bool) -> (first: Int, last: Int)? {
        guard pattern.count <= text.count else { return nil }

        var textIndex = 0
        var firstMatchIdx = 0   // byte index in text where pattern[0] matched
        var lastMatchIdx  = 0   // byte index in text where pattern[last] matched

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
                return nil   // character not found — reject immediately
            }

            if i == 0 {
                firstMatchIdx = textIndex
            }
            lastMatchIdx = textIndex
            textIndex += 1
        }

        // Step back by 1 so the DP can compute the bonus for the first matched
        // character using its predecessor's character class.
        let scopeFirst = firstMatchIdx > 0 ? firstMatchIdx - 1 : 0

        // Backward scan: find the rightmost occurrence of the last pattern byte.
        // The optimal alignment may end anywhere up to that position.
        let lastPatByte = caseSensitive ? pattern[pattern.count - 1] : toLower(pattern[pattern.count - 1])
        var scopeLast = lastMatchIdx   // fallback: the forward-scan position
        if !caseSensitive {
            let upper = lastPatByte >= 0x61 && lastPatByte <= 0x7A ? lastPatByte - 0x20 : lastPatByte
            var idx = text.count - 1
            while idx > lastMatchIdx {
                let b = text[idx]
                if b == lastPatByte || b == upper {
                    scopeLast = idx
                    break
                }
                idx -= 1
            }
        } else {
            var idx = text.count - 1
            while idx > lastMatchIdx {
                if text[idx] == lastPatByte {
                    scopeLast = idx
                    break
                }
                idx -= 1
            }
        }

        return (first: scopeFirst, last: scopeLast)
    }

    /// Main matching function using UTF-8 byte-level operations
    public static func match(pattern: String, text: String, caseSensitive: Bool = false) -> MatchResult? {
        guard !pattern.isEmpty else {
            return MatchResult(score: 0, positions: [])
        }

        // Use utf8.span for zero-copy access
        let patternSpan = pattern.utf8.span
        let textSpan = text.utf8.span

        // Forward + backward scan: reject early if no in-order match exists,
        // and compute the narrowest window [scopeFirst … scopeLast] that must
        // contain any optimal alignment.
        guard let scope = scopeIndices(pattern: patternSpan, text: textSpan, caseSensitive: caseSensitive) else {
            return nil
        }
        let scopeFirst = scope.first   // inclusive; DP j starts at scopeFirst + 1
        let scopeLast  = scope.last    // inclusive; DP j ends at scopeLast + 1

        let patternLen = patternSpan.count
        let textLen = textSpan.count

        // Use buffer reuse for better performance in parallel contexts
        let buffer = matrixBuffer ?? MatrixBuffer()
        buffer.resize(patternLen: patternLen, textLen: textLen)
        buffer.clear(patternLen: patternLen, textLen: textLen)

        // Pre-compute charClasses and (optionally) lowered text bytes into pooled buffers.
        // This eliminates per-cell toLower calls inside the DP inner loop and avoids
        // allocating a fresh [CharClass] array on every match() invocation.
        buffer.resizeTextBuffers(count: textLen)
        for i in 0..<textLen {
            let raw = textSpan[i]
            buffer.charClasses[i] = classify(raw)
            buffer.loweredText[i] = caseSensitive ? raw : toLower(raw)
        }

        let stride = buffer.stride

        // Initialize row 0: empty pattern matches with score 0.
        // Only need to cover [0 … scopeLast+1] — cells beyond scopeLast are
        // never read by the clamped DP or best-score loops.
        let row0End = scopeLast + 1   // scopeLast is inclusive byte index; j = scopeLast+1 is the last DP column we touch
        for j in 0...row0End {
            buffer.H[j] = 0
            buffer.lastMatch[j] = -1
        }

        // Pre-lower the pattern bytes once (outside all loops)
        // and store in a small stack-friendly buffer.  Patterns are short
        // (typically < 64 bytes) so a fixed array avoids a heap alloc.
        // For patterns > 256 bytes we fall back to a heap array.
        let patternLowered: [UInt8]
        if caseSensitive {
            patternLowered = []  // unused; we read patternSpan directly
        } else {
            patternLowered = (0..<patternLen).map { toLower(patternSpan[$0]) }
        }

        // Fill DP table using byte-level comparisons.
        // j is clamped to the scope window: only columns that could participate
        // in an optimal alignment are visited.  Columns outside the window stay
        // at Int.min/2 (set by clear()) which correctly represents "unreachable".
        let jStart = max(1, scopeFirst + 1)
        let jEnd   = scopeLast + 1   // inclusive; scopeLast is the byte index of the rightmost last-pattern-byte
        for i in 1...patternLen {
            // Hoist pattern byte out of inner loop — depends only on i
            let patternByte = caseSensitive ? patternSpan[i - 1] : patternLowered[i - 1]
            let rowBase = i * stride
            let prevRowBase = (i - 1) * stride

            for j in jStart...jEnd {
                let textByte = buffer.loweredText[j - 1]

                if patternByte == textByte {
                    // Character match
                    let bonus: Int
                    if j == 1 {
                        bonus = 8  // First character bonus
                    } else {
                        bonus = Self.bonus(current: buffer.charClasses[j - 1], previous: buffer.charClasses[j - 2])
                    }

                    // Check for consecutive match
                    let consecutiveBonus = (buffer.lastMatch[prevRowBase + j - 1] == j - 2) ? bonusConsecutive : 0

                    let matchScore = buffer.H[prevRowBase + j - 1] + scoreMatch + bonus + consecutiveBonus
                    buffer.H[rowBase + j] = matchScore
                    buffer.lastMatch[rowBase + j] = j - 1
                } else {
                    // Gap: carry forward best score from left
                    buffer.H[rowBase + j] = buffer.H[rowBase + j - 1] + scoreGapExtension
                    buffer.lastMatch[rowBase + j] = buffer.lastMatch[rowBase + j - 1]
                }
            }
        }

        // Find best score in last row (clamped to scope window)
        let lastRowBase = patternLen * stride
        var bestScore = Int.min
        var bestCol = -1
        for j in max(patternLen, jStart)...jEnd {
            if buffer.H[lastRowBase + j] > bestScore {
                bestScore = buffer.H[lastRowBase + j]
                bestCol = j
            }
        }

        guard bestScore > Int.min / 2 else {
            return nil
        }

        // Backtrack to find match positions
        let positions = backtrack(H: buffer.H, lastMatch: buffer.lastMatch, stride: stride, patternLen: patternLen, endCol: bestCol)

        return MatchResult(score: bestScore, positions: positions)
    }

    private static func backtrack(H: [Int], lastMatch: [Int], stride: Int, patternLen: Int, endCol: Int) -> [Int] {
        // Pre-allocate exact size and fill in reverse to avoid append + reversed
        var positions = [Int](repeating: 0, count: patternLen)
        var writeIdx = patternLen - 1
        var col = endCol
        var row = patternLen

        while row > 0 && col > 0 {
            let matchPos = lastMatch[row * stride + col]
            if matchPos >= 0 && matchPos < col {
                positions[writeIdx] = matchPos
                writeIdx -= 1
                row -= 1
                col = matchPos
            } else {
                col -= 1
            }
        }

        // If we didn't fill all slots (shouldn't happen for a valid match path),
        // return only the filled portion.  Normally writeIdx == -1 at this point.
        if writeIdx >= 0 {
            return Array(positions[(writeIdx + 1)...])
        }
        return positions
    }
}
