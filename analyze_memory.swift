#!/usr/bin/env swift
import Foundation

// Simple memory analyzer to calculate theoretical memory footprint

struct MemoryAnalysis {
    let lineCount: Int = 827_707
    let totalBytes: Int = 97_794_657
    let avgLineLength: Int

    init() {
        self.avgLineLength = totalBytes / lineCount
    }

    func analyze() {
        print("=== fltr Memory Analysis ===\n")
        print("Input Statistics:")
        print("  Lines: \(lineCount.formatted())")
        print("  Total bytes: \(totalBytes.formatted()) (~\((totalBytes / 1024 / 1024)) MB)")
        print("  Average line length: \(avgLineLength) bytes\n")

        // 1. TextBuffer
        let textBufferSize = totalBytes
        print("1. TextBuffer (raw text):")
        print("   Size: \(textBufferSize.formatted()) bytes (~\((textBufferSize / 1024 / 1024)) MB)")
        print("   Note: After shrinkToFit(), this should be exact\n")

        // 2. ChunkStore
        let chunksNeeded = (lineCount + 99) / 100  // Round up
        let itemSize = 12  // Int32 + UInt32 + UInt32
        let itemsPerChunk = 100
        let chunkSize = itemSize * itemsPerChunk  // 1200 bytes per chunk
        let chunkStoreSize = chunksNeeded * chunkSize
        print("2. ChunkStore (item metadata):")
        print("   Chunks needed: \(chunksNeeded.formatted())")
        print("   Item size: \(itemSize) bytes")
        let chunkSizeKB = Double(chunkSize) / 1024.0
        print("   Chunk size: \(chunkSize) bytes (~\(chunkSizeKB) KB)")
        print("   Total chunk storage: \(chunkStoreSize.formatted()) bytes (~\((chunkStoreSize / 1024 / 1024)) MB)\n")

        // 3. Estimated total
        let estimatedTotal = textBufferSize + chunkStoreSize
        print("3. Core storage (TextBuffer + Chunks):")
        print("   Total: \(estimatedTotal.formatted()) bytes (~\((estimatedTotal / 1024 / 1024)) MB)\n")

        // 4. Overhead analysis
        let arrayOverhead = 32 // Array header
        let frozenArrays = chunksNeeded * arrayOverhead
        print("4. Additional overhead:")
        print("   Array headers: ~\(frozenArrays.formatted()) bytes")
        print("   Actor overhead: ~few KB")
        print("   Swift runtime: ~few MB\n")

        // 5. Compare with ideal (fzf-like)
        print("5. Comparison with fzf approach:")
        print("   fzf stores: text + minimal metadata")
        print("   Estimated fzf footprint: ~\((totalBytes / 1024 / 1024)) MB (text) + ~\((lineCount * 8 / 1024 / 1024)) MB (pointers)")
        print("   = ~\(((totalBytes + lineCount * 8) / 1024 / 1024)) MB\n")

        // 6. ChunkCache potential
        print("6. ChunkCache potential memory:")
        print("   Max cached results per chunk: 20 items")
        print("   MatchedItem size: ~40-50 bytes (Item 12B + MatchResult ~20B + UInt64 8B)")
        print("   If all chunks cached with max results:")
        print("   \(chunksNeeded) chunks × 20 items × 45 bytes = \((chunksNeeded * 20 * 45).formatted()) bytes (~\((chunksNeeded * 20 * 45 / 1024 / 1024)) MB)")
        print("   Note: This only happens with queries matching ≤20 items per chunk\n")

        print("=== Summary ===")
        let minMB = estimatedTotal / 1024 / 1024
        print("Theoretical minimum: ~\(minMB) MB")
        let withCachingMB = (estimatedTotal + chunksNeeded * 20 * 45 + 5 * 1024 * 1024) / 1024 / 1024
        print("With caching + overhead: ~\(withCachingMB) MB")
        print("\nReported actual usage:")
        print("  fltr: 243 MB")
        print("  fzf:  148 MB")
        print("\nDifference: 95 MB (64% more)")
        print("\nPotential causes:")
        print("  1. Swift runtime overhead (~10-20 MB)")
        print("  2. Array growth headroom not reclaimed (if shrinkToFit not called)")
        print("  3. ChunkCache accumulation")
        print("  4. UI buffers and state")
        print("  5. Matrix buffers in TaskLocal storage")
    }
}

let analyzer = MemoryAnalysis()
analyzer.analyze()
