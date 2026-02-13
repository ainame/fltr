#!/usr/bin/env swift
import Foundation

// Memory hotspot analysis for fltr

print("=== Memory Hotspot Analysis ===\n")

let lineCount = 827_707
let totalTextBytes = 97_794_657
let maxLineLength = 420

// Base storage
print("1. Base Storage:")
let textBuffer = totalTextBytes
let chunkMetadata = (lineCount / 100 + 1) * 100 * 12
print("   TextBuffer: \(textBuffer / 1024 / 1024) MB")
print("   Chunk metadata: \(chunkMetadata / 1024 / 1024) MB")
print("   Subtotal: \((textBuffer + chunkMetadata) / 1024 / 1024) MB\n")

// MatchedItem size breakdown
print("2. MatchedItem Structure:")
print("   Item: 12 bytes (index: Int32, offset: UInt32, length: UInt32)")
print("   MatchResult:")
print("     - score: 8 bytes (Int)")
print("     - positions: ~8 bytes (Array header) + data")
print("       * Empty: 16 bytes total")
print("       * 5 positions: 16 + 5*8 = 56 bytes")
print("       * 10 positions: 16 + 10*8 = 96 bytes")
print("   points: 8 bytes (UInt64)")
print("   Conservative estimate: ~40 bytes (empty positions)")
print("   Typical estimate: ~80 bytes (5 positions)")
print("   High estimate: ~120 bytes (10 positions)\n")

// ResultMerger partition storage
print("3. ResultMerger Partition Storage:")
print("   When matching ALL items (empty query uses chunk-backed path):")
let cpuCount = 10
let selectivity50 = lineCount / 2  // 50% selectivity
let selectivity90 = Int(Double(lineCount) * 0.9)  // 90% selectivity

func calculatePartitionMemory(matchCount: Int, bytesPerItem: Int) -> Int {
    // Each partition stores matched items
    return matchCount * bytesPerItem
}

for (label, matchCount, bytesPerItem) in [
    ("50% selectivity, 40B/item", selectivity50, 40),
    ("50% selectivity, 80B/item", selectivity50, 80),
    ("90% selectivity, 40B/item", selectivity90, 40),
    ("90% selectivity, 80B/item", selectivity90, 80),
] {
    let mem = calculatePartitionMemory(matchCount: matchCount, bytesPerItem: bytesPerItem)
    print("   \(label): \(mem / 1024 / 1024) MB")
}
print("")

// MergerCache
print("4. MergerCache:")
print("   Max cached results: 100,000 items")
print("   @ 40 bytes/item: \(100_000 * 40 / 1024 / 1024) MB")
print("   @ 80 bytes/item: \(100_000 * 80 / 1024 / 1024) MB")
print("   Note: Only one query cached at a time\n")

// ChunkCache
print("5. ChunkCache:")
let chunks = lineCount / 100 + 1
print("   Total chunks: \(chunks)")
print("   Max cached per chunk: 20 items")
print("   If all chunks cached with max:")
let chunkCacheWorst = chunks * 20 * 80
print("   \(chunks) × 20 × 80 bytes = \(chunkCacheWorst / 1024 / 1024) MB")
print("   Realistic (30% of chunks): \(chunkCacheWorst * 30 / 100 / 1024 / 1024) MB\n")

// Matrix buffers (per-task via @TaskLocal)
print("6. Matrix Buffers (TaskLocal, one per worker):")
print("   Workers: ~\(cpuCount) (CPU count)")
print("   Algorithm buffer (2D [[Int]]):")
let patternLen = 20  // typical query length
let matrixSize = 2 * (patternLen + 1) * (maxLineLength + 1) * 8
print("     Pattern: \(patternLen), MaxText: \(maxLineLength)")
print("     Size: 2 × \((patternLen+1)) × \((maxLineLength+1)) × 8 = \(matrixSize / 1024) KB per worker")
print("     Total: \(matrixSize * cpuCount / 1024) KB")
print("   Utf8 buffer (I16, I32):")
let utf8BufferSize = maxLineLength * 2 + maxLineLength * 4
print("     I16: \(maxLineLength * 2) bytes")
print("     I32: \(maxLineLength * 4) bytes")
print("     Total per worker: \(utf8BufferSize) bytes")
print("     Total all workers: \(utf8BufferSize * cpuCount / 1024) KB\n")

// Array growth overhead
print("7. Array Growth Overhead:")
print("   Swift arrays grow by ~1.5-2x when full")
print("   If shrinkToFit() NOT called or ineffective:")
let textOverhead = textBuffer * 30 / 100
let chunkOverhead = chunkMetadata * 30 / 100
print("     TextBuffer: +\(textOverhead / 1024 / 1024) MB")
print("     ChunkStore: +\(chunkOverhead / 1024 / 1024) MB")
print("     Partition arrays: +5-15 MB (estimated)")
print("   Total potential overhead: ~\((textOverhead + chunkOverhead + 10_000_000) / 1024 / 1024) MB\n")

// Swift runtime and other
print("8. Swift Runtime & Miscellaneous:")
print("   Swift runtime: ~10-20 MB")
print("   UI buffers: ~1-2 MB")
print("   Actor overhead: <1 MB")
print("   Subtotal: ~15 MB\n")

// Summary
print("=== Projected Memory Usage ===")
print("Minimum (no matching, all optimizations):")
let minimum = (textBuffer + chunkMetadata) / 1024 / 1024 + 15
print("  \(minimum) MB\n")

print("Typical (moderate matching, e.g., 50% selectivity):")
let typical = minimum + selectivity50 * 80 / 1024 / 1024 + 2
print("  \(typical) MB (base + partition storage + cache)\n")

print("Worst case (high selectivity matching + growth overhead):")
let worst = minimum + selectivity90 * 80 / 1024 / 1024 + 30 + 7
print("  \(worst) MB (base + partitions + overhead + caches)\n")

print("=== FINDINGS ===")
print("Primary memory consumers:")
print("1. ★★★ ResultMerger partitions storing MatchedItem arrays")
print("   - Each MatchedItem: ~40-120 bytes (vs 12 bytes for Item)")
print("   - High-selectivity queries store most items as MatchedItems")
print("   - Example: 400k matches × 80 bytes = 32 MB")
print("")
print("2. ★★ Array growth overhead")
print("   - TextBuffer/ChunkStore grow by 1.5-2x, leave ~30% headroom")
print("   - If shrinkToFit() not called or partitions not shrunk")
print("   - Estimated: 20-30 MB")
print("")
print("3. ★ ChunkCache accumulation")
print("   - Can grow to 7-10 MB with many queries")
print("")
print("fzf comparison:")
print("  fzf (Go): ~148 MB")
print("  fltr (Swift): ~243 MB")
print("  Difference: ~95 MB")
print("")
print("Likely explanation:")
print("  Base storage: same (~100 MB)")
print("  MatchedItem arrays: +30-50 MB (Swift vs Go slice overhead)")
print("  Array growth overhead: +20-30 MB")
print("  Swift runtime: +10-15 MB")
print("  = ~60-95 MB difference ✓")
