import Foundation

/// Optimized fuzzy matching using UTF-8 byte-level operations.
/// Mirrors fzf's FuzzyMatchV2 Phase 1–4 structure:
///   Phase 1 – asciiFuzzyIndex  (scope narrowing: forward + backward scan)
///   Phase 2 – single-pass H0 / C0 / B / T computation
///   Phase 3 – DP fill with per-row left bound F[i], width-relative indexing
///   Phase 4 – backtrack by re-comparing H / C  (no lastMatch matrix)
///
/// Key perf techniques from fzf:
///   • int16 scores            – halves memory bandwidth vs Int64
///   • width = lastIdx − F[0] + 1 – narrow matrix, not full textLen
///   • per-row left bound F[i] – skips impossible columns per row
///   • slab-style pooled buffer via @TaskLocal
///   • 128-entry ASCII LUT for classify  (single load, no branches)
///   • precomputed 6×6 bonus table + per-position B[] cache
///   • byte-level toLower  (ASCII fast path)
public struct Utf8FuzzyMatch: Sendable {

    // ─── Scoring constants (identical to fzf) ─────────────────────────────
    static let scoreMatch:               Int16 = 16
    static let scoreGapStart:            Int16 = -3
    static let scoreGapExtension:        Int16 = -1
    static let bonusBoundary:            Int16 = scoreMatch / 2           // 8
    static let bonusConsecutive:         Int16 = -(scoreGapStart + scoreGapExtension) // 4
    static let bonusFirstCharMultiplier: Int16 = 2

    // ─── 128-entry ASCII class LUT ─────────────────────────────────────────
    // Maps each ASCII byte (0…127) directly to a class index (0…5).
    // Non-ASCII bytes (≥ 128) are treated as class 4 (letter).
    //   0 = whitespace   (\t \n \r SP)
    //   1 = delimiter    (_ - / \ . :)
    //   2 = lower        (a-z)
    //   3 = upper        (A-Z)
    //   4 = letter       (everything else / non-ASCII)
    //   5 = number       (0-9)
    // Mirrors fzf's asciiCharClasses[] initialised in Init("path").
    @usableFromInline
    static let classLUT: [UInt8] = {
        var lut = [UInt8](repeating: 4, count: 128)   // default: letter
        // whitespace
        lut[0x09] = 0; lut[0x0A] = 0; lut[0x0D] = 0; lut[0x20] = 0
        // delimiter: _ - / \ . :
        lut[0x5F] = 1; lut[0x2D] = 1; lut[0x2F] = 1
        lut[0x5C] = 1; lut[0x2E] = 1; lut[0x3A] = 1
        // lower a-z
        for b in 0x61...0x7A { lut[b] = 2 }
        // upper A-Z
        for b in 0x41...0x5A { lut[b] = 3 }
        // number 0-9
        for b in 0x30...0x39 { lut[b] = 5 }
        return lut
    }()

    // ─── 6×6 bonus table  (path scheme) ────────────────────────────────────
    // bonusMatrix[prev][cur].  Flat: index = prev * 6 + cur
    @usableFromInline
    static let bonusTable: [Int16] = {
        let bWhite:    Int16 = 8   // path: bonusBoundaryWhite == bonusBoundary
        let bDelim:    Int16 = 9   // bonusBoundary + 1
        let bCamel:    Int16 = 7   // bonusBoundary + scoreGapExtension

        var t = [Int16](repeating: 0, count: 36)
        // isWord: classes 2 (lower), 3 (upper), 4 (letter), 5 (number)
        for c in 0..<6 {
            let isWord = (c == 2 || c == 3 || c == 4 || c == 5)
            if isWord {
                t[0*6+c] = bWhite   // prev = whitespace
                t[1*6+c] = bDelim   // prev = delimiter
            }
        }
        // camelCase: lower(2)→upper(3)
        t[2*6+3] = bCamel
        // (non-number)→number: prev ∈ {2,3,4} only.
        // prev=0 (whitespace) and prev=1 (delimiter) already have the higher
        // boundary bonus set above; fzf's boundary check fires first (continue).
        for p in [2,3,4] { t[p*6+5] = bCamel }
        // number→number stays 0 (already default)
        return t
    }()

    // ─── Pooled slab buffer ────────────────────────────────────────────────
    /// I16 layout (window width W, pattern length M):
    ///   H0  [0       … W)            row-0 scores
    ///   C0  [W       … 2W)           row-0 consecutive counts
    ///   B   [2W      … 3W)           per-position bonus
    ///   H   [3W      … 3W + W*M)     DP rows 0…M−1
    ///   C   [3W+W*M  … 3W + 2W*M)   consecutive rows 0…M−1
    ///
    /// I32 layout:
    ///   F   [0 … M)     first-occurrence (global index) of each pattern byte
    ///   T   [M … M+W)   lowered text bytes as Int32
    final class MatrixBuffer: @unchecked Sendable {
        var I16: [Int16] = []
        var I32: [Int32] = []

        @inlinable func ensureI16(_ n: Int) {
            if I16.count < n { I16 = [Int16](repeating: 0, count: n) }
        }
        @inlinable func ensureI32(_ n: Int) {
            if I32.count < n { I32 = [Int32](repeating: 0, count: n) }
        }
    }

    @TaskLocal static var matrixBuffer: MatrixBuffer?

    // ─── ASCII helpers ─────────────────────────────────────────────────────
    @inlinable
    static func toLower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? (b | 0x20) : b
    }

    /// Classify a byte to class index 0…5 using the LUT.
    /// Non-ASCII (≥ 128) → 4 (letter).
    @inlinable
    static func classOf(_ b: UInt8) -> Int {
        Int(b < 128 ? classLUT[Int(b)] : 4)
    }

    // ─── Phase 1: asciiFuzzyIndex ──────────────────────────────────────────
    /// Forward scan: populate F[0…M−1].  Backward scan: widen right bound.
    /// Returns nil on rejection.
    /// Uses memchr (SIMD-optimized) for fast byte scanning, following fzf's strategy.
    @inlinable
    static func asciiFuzzyIndex(
        pattern: Span<UInt8>, text: Span<UInt8>,
        caseSensitive: Bool,
        F: UnsafeMutablePointer<Int32>
    ) -> (minIdx: Int, maxIdx: Int)? {
        let M = pattern.count, N = text.count
        guard M <= N else { return nil }

        var result: (minIdx: Int, maxIdx: Int)?
        text.withUnsafeBufferPointer { textBuf in
            pattern.withUnsafeBufferPointer { patBuf in
                guard let textBase = textBuf.baseAddress,
                      let patBase = patBuf.baseAddress else { return }
                
                var idx = 0, lastIdx = 0
                for pidx in 0..<M {
                    let pb = caseSensitive ? patBase[pidx] : toLower(patBase[pidx])
                    
                    // Use memchr for SIMD-optimized byte search (case-sensitive)
                    if caseSensitive {
                        guard let ptr = memchr(textBase.advanced(by: idx), 
                                              Int32(pb), 
                                              N - idx) else { return }
                        let foundPtr = UnsafePointer<UInt8>(ptr.assumingMemoryBound(to: UInt8.self))
                        idx = foundPtr - textBase
                    } else {
                        // Case-insensitive: need to check both lowercase and uppercase
                        // Use memchr to find lowercase, then check for uppercase before it
                        let upper: UInt8 = (pb >= 0x61 && pb <= 0x7A) ? pb - 0x20 : pb
                        
                        var foundIdx = N
                        if let ptr = memchr(textBase.advanced(by: idx), Int32(pb), N - idx) {
                            let foundPtr = UnsafePointer<UInt8>(ptr.assumingMemoryBound(to: UInt8.self))
                            foundIdx = foundPtr - textBase
                        }
                        if pb != upper {
                            if let ptr = memchr(textBase.advanced(by: idx), Int32(upper), N - idx) {
                                let foundPtr = UnsafePointer<UInt8>(ptr.assumingMemoryBound(to: UInt8.self))
                                let upperIdx = foundPtr - textBase
                                foundIdx = min(foundIdx, upperIdx)
                            }
                        }
                        if foundIdx >= N { return }
                        idx = foundIdx
                    }
                    
                    F[pidx] = Int32(idx)
                    lastIdx = idx
                    idx += 1
                }

                let minIdx = (Int(F[0]) > 0) ? Int(F[0]) - 1 : 0

                // backward: rightmost occurrence of last pattern byte
                let lastPb = caseSensitive ? patBase[M-1] : toLower(patBase[M-1])
                var scopeLast = lastIdx
                if caseSensitive {
                    var i = N - 1
                    while i > lastIdx { if textBase[i] == lastPb { scopeLast = i; break }; i -= 1 }
                } else {
                    let upper: UInt8 = (lastPb >= 0x61 && lastPb <= 0x7A) ? lastPb - 0x20 : lastPb
                    var i = N - 1
                    while i > lastIdx {
                        let b = textBase[i]
                        if b == lastPb || b == upper { scopeLast = i; break }
                        i -= 1
                    }
                }
                result = (minIdx: minIdx, maxIdx: scopeLast + 1)
            }
        }
        return result
    }

    // ─── Main entry ────────────────────────────────────────────────────────

    /// Zero-copy overload: *textBuf* is a pre-sliced view into a ``TextBuffer``.
    /// Avoids constructing a ``String`` on the hot path.
    public static func match(pattern: String, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool = false) -> MatchResult? {
        guard !pattern.isEmpty else { return MatchResult(score: 0, positions: []) }

        let patternSpan = pattern.utf8.span
        let textSpan = Span(_unsafeElements: textBuf)
        let M = patternSpan.count, N = textSpan.count
        guard M <= N else { return nil }

        return _matchCore(patSpan: patternSpan, txtSpan: textSpan, M: M, N: N, caseSensitive: caseSensitive)
    }

    /// Span overload: pattern is already a byte slice (e.g. a token extracted
    /// from a multi-token pattern).  Zero allocation — no String round-trip.
    static func match(patternSpan: Span<UInt8>, textBuf: UnsafeBufferPointer<UInt8>, caseSensitive: Bool) -> MatchResult? {
        guard !patternSpan.isEmpty else { return MatchResult(score: 0, positions: []) }

        let textSpan = Span(_unsafeElements: textBuf)
        let M = patternSpan.count, N = textSpan.count
        guard M <= N else { return nil }

        return _matchCore(patSpan: patternSpan, txtSpan: textSpan, M: M, N: N, caseSensitive: caseSensitive)
    }

    public static func match(pattern: String, text: String, caseSensitive: Bool = false) -> MatchResult? {
        guard !pattern.isEmpty else { return MatchResult(score: 0, positions: []) }

        let patSpan = pattern.utf8.span
        let txtSpan = text.utf8.span
        let M = patSpan.count, N = txtSpan.count
        guard M <= N else { return nil }

        return _matchCore(patSpan: patSpan, txtSpan: txtSpan, M: M, N: N, caseSensitive: caseSensitive)
    }

    // ─── Shared core ───────────────────────────────────────────────────────
    private static func _matchCore(patSpan: Span<UInt8>, txtSpan: Span<UInt8>, M: Int, N: Int, caseSensitive: Bool) -> MatchResult? {
        let buf = matrixBuffer ?? MatrixBuffer()
        buf.ensureI32(M + N)

        // ── Phase 1 ──────────────────────────────────────────────────────
        guard let scope = asciiFuzzyIndex(
            pattern: patSpan, text: txtSpan,
            caseSensitive: caseSensitive,
            F: buf.I32.withUnsafeMutableBufferPointer { $0.baseAddress! }
        ) else { return nil }

        let minIdx = scope.minIdx
        let W      = scope.maxIdx - minIdx

        buf.ensureI16(3 * W + 2 * W * M)

        let offH0 = 0,  offC0 = W,  offB = 2 * W
        let offH  = 3 * W,          offC = 3 * W + W * M
        let offT  = M   // in I32

        // ── Phase 2 ──────────────────────────────────────────────────────
        var maxScore:    Int16 = 0
        var maxScorePos: Int   = 0

        buf.I16.withUnsafeMutableBufferPointer { i16buf in
            buf.I32.withUnsafeMutableBufferPointer { i32buf in
                let i16 = i16buf.baseAddress!
                let i32 = i32buf.baseAddress!

                let H0  = i16 + offH0
                let C0  = i16 + offC0
                let B   = i16 + offB
                let T   = i32 + offT

                Self.classLUT.withUnsafeBufferPointer { lutBuf in
                    let lut = lutBuf.baseAddress!
                    Self.bonusTable.withUnsafeBufferPointer { btBuf in
                        let bt = btBuf.baseAddress!
                        patSpan.withUnsafeBufferPointer { patRaw in
                            txtSpan.withUnsafeBufferPointer { txtRaw in
                                let pat = patRaw.baseAddress!
                                let txt = txtRaw.baseAddress!

                                let pchar0: UInt8 = caseSensitive ? pat[0] : toLower(pat[0])
                                var prevH0: Int16 = 0
                                var prevCls: Int  = 1   // delimiter (path scheme initialCharClass)
                                var inGap = false

                                for off in 0..<W {
                                    let raw = txt[minIdx + off]
                                    let cls = Int(raw < 128 ? lut[Int(raw)] : 4)
                                    let ch: UInt8 = (!caseSensitive && cls == 3) ? (raw | 0x20) : raw
                                    T[off] = Int32(ch)

                                    let bonus = bt[prevCls * 6 + cls]
                                    B[off]    = bonus
                                    prevCls   = cls

                                    if ch == pchar0 {
                                        let score = scoreMatch + bonus * bonusFirstCharMultiplier
                                        H0[off]  = score
                                        C0[off]  = 1
                                        if M == 1 && score > maxScore {
                                            maxScore    = score
                                            maxScorePos = off
                                        }
                                        inGap = false
                                    } else {
                                        H0[off] = max(prevH0 + (inGap ? scoreGapExtension : scoreGapStart), 0)
                                        C0[off] = 0
                                        inGap   = true
                                    }
                                    prevH0 = H0[off]
                                }
                            }
                        }
                    }
                }
            }
        }

        // Single-char fast path
        if M == 1 {
            return MatchResult(score: Int(maxScore), positions: [minIdx + maxScorePos])
        }

        // ── Phase 3: DP fill ─────────────────────────────────────────────
        let f0    = Int(buf.I32[0])
        let f0rel = f0 - minIdx

        buf.I16.withUnsafeMutableBufferPointer { i16buf in
            buf.I32.withUnsafeBufferPointer  { i32buf in
                let i16 = i16buf.baseAddress!
                let i32 = i32buf.baseAddress!
                let H   = i16 + offH
                let C   = i16 + offC
                let H0p = i16 + offH0
                let C0p = i16 + offC0
                let B   = i16 + offB
                let T   = i32 + offT
                let Fp  = i32              // F[0…M−1]

                // Clear H and C so that cells below each row's fRel —
                // which the DP loop never writes — do not retain stale
                // positive scores from a previous call on a reused buffer.
                // Without this the backtrack's best-score scan and diagonal
                // reads can pick up phantom scores and diverge, producing
                // garbage (often negative) positions.
                H.initialize(repeating: 0, count: W * M)
                C.initialize(repeating: 0, count: W * M)

                // Row 0 ← H0 / C0
                for j in f0rel..<W {
                    H[j] = H0p[j]
                    C[j] = C0p[j]
                }

                patSpan.withUnsafeBufferPointer { patRaw in
                    let pat = patRaw.baseAddress!

                    for pidx in 1..<M {
                        let fRel = Int(Fp[pidx]) - minIdx
                        let pch  = caseSensitive ? pat[pidx] : toLower(pat[pidx])
                        let row  = pidx * W
                        let prev = (pidx - 1) * W

                        var inGap: Bool = false
                        var hleft: Int16 = 0

                        for off in fRel..<W {
                            let s2 = hleft + (inGap ? scoreGapExtension : scoreGapStart)

                            var s1: Int16 = Int16.min / 2
                            var consecutive: Int16 = 0

                            let ch = UInt8(truncatingIfNeeded: T[off])
                            if pch == ch {
                                let hdiag: Int16 = (off > 0) ? H[prev + off - 1] : 0
                                s1 = hdiag + scoreMatch
                                var b = B[off]
                                consecutive = (off > 0) ? C[prev + off - 1] + 1 : 1

                                if consecutive > 1 {
                                    let fb = B[off - Int(consecutive) + 1]
                                    if b >= bonusBoundary && b > fb {
                                        consecutive = 1
                                    } else {
                                        b = max(b, max(fb, bonusConsecutive))
                                    }
                                }
                                if s1 + b < s2 {
                                    s1 += B[off]
                                    consecutive = 0
                                } else {
                                    s1 += b
                                }
                            }

                            C[row + off] = consecutive
                            inGap        = s1 < s2
                            let score    = max(s1, max(s2, 0))
                            H[row + off] = score
                            hleft        = score
                        }
                    }
                }
            }
        }

        // ── Best score in last row ─────────────────────────────────────
        let lastRow = (M - 1) * W
        var bestScore: Int16 = 0
        var bestCol   = f0rel
        buf.I16.withUnsafeBufferPointer { i16buf in
            let H = i16buf.baseAddress! + offH
            for j in f0rel..<W {
                if H[lastRow + j] > bestScore {
                    bestScore = H[lastRow + j]
                    bestCol   = j
                }
            }
        }
        guard bestScore > 0 else { return nil }

        // ── Phase 4: backtrack ─────────────────────────────────────────
        var positions = [UInt16](repeating: 0, count: M)

        buf.I16.withUnsafeBufferPointer { i16buf in
            buf.I32.withUnsafeBufferPointer { i32buf in
                positions.withUnsafeMutableBufferPointer { posBuf in
                    let H   = i16buf.baseAddress! + offH
                    let C   = i16buf.baseAddress! + offC
                    let Fp  = i32buf.baseAddress!
                    let pos = posBuf.baseAddress!

                    var i = M - 1
                    var j = bestCol
                    var preferMatch = true

                    while true {
                        let row = i * W
                        let s   = H[row + j]

                        var s1: Int16 = 0
                        var s2: Int16 = 0

                        let fI = Int(Fp[i]) - minIdx
                        if i > 0 && j >= fI {
                            s1 = (j > 0) ? H[(i-1)*W + j - 1] : 0
                        }
                        if j > fI {
                            s2 = H[row + j - 1]
                        }

                        if s > s1 && (s > s2 || (s == s2 && preferMatch)) {
                            pos[i] = UInt16(minIdx + j)
                            if i == 0 { break }
                            i -= 1
                        }

                        let curC  = C[row + j]
                        let nextOff = row + W + j + 1
                        let nextC: Int16 = (nextOff < M * W) ? C[nextOff] : 0
                        preferMatch = curC > 1 || nextC > 0
                        j -= 1
                    }
                }
            }
        }

        return MatchResult(score: Int16(bestScore), positions: positions)
    }
}
