#!/usr/bin/env swift
import Foundation

print("=== Analyzing Initial Load Memory ===\n")

let lines = 827_707
let bytes = 97_794_657

// 1. TextBuffer growth
print("1. TextBuffer growth overhead:")
print("   Actual bytes: \(bytes) (\(bytes / 1024 / 1024) MB)")

// Simulate array growth via append
var growing = [UInt8]()
for _ in 0..<bytes {
    growing.append(0)
}
print("   After growth: capacity = \(growing.capacity)")
let textOverhead = growing.capacity - bytes
print("   Overhead: \(textOverhead) bytes (\(textOverhead / 1024 / 1024) MB)")
let textPct = (textOverhead * 100) / bytes
print("   Percentage: \(textPct)%\n")

// 2. ChunkStore growth
print("2. ChunkStore growth overhead:")
let chunks = (lines + 99) / 100  // 8278 chunks
let chunkSize = 1200  // InlineArray<100> of Item (12 bytes each)
let chunkBytes = chunks * chunkSize
print("   Chunks: \(chunks)")
print("   Actual bytes: \(chunkBytes) (\(chunkBytes / 1024 / 1024) MB)")

// Simulate
struct MockChunk {
    let data: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)  // ~1200 bytes
}

var chunkArray = [MockChunk]()
let dummy = MockChunk(data: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
for _ in 0..<chunks {
    chunkArray.append(dummy)
}
print("   After growth: capacity = \(chunkArray.capacity)")
let chunkOverhead = (chunkArray.capacity - chunks) * chunkSize
print("   Overhead: \(chunkOverhead) bytes (\(chunkOverhead / 1024 / 1024) MB)")
let chunkPct = ((chunkArray.capacity - chunks) * 100) / chunks
print("   Percentage: \(chunkPct)%\n")

// Total
print("=== Summary ===")
let totalActual = bytes + chunkBytes
let totalWithOverhead = growing.capacity + chunkArray.capacity * chunkSize
print("Actual data: \(totalActual / 1024 / 1024) MB")
print("With growth overhead: \(totalWithOverhead / 1024 / 1024) MB")
print("Overhead: \((totalWithOverhead - totalActual) / 1024 / 1024) MB")
print("")
print("Reported: 234.8 MB")
print("Accounted for: \(totalWithOverhead / 1024 / 1024) MB (data + overhead)")
print("Swift runtime: ~15-20 MB")
print("UI: ~2-5 MB")
print("")
let gap = 234 - (totalWithOverhead / 1024 / 1024) - 18
print("Still unexplained: ~\(gap) MB")
print("")
print("=== Ideas to Reduce Memory ===")
print("1. Pre-calculate input size and use reserveCapacity(exact)")
print("   - Pass through stdin twice: count, then read")
print("   - Or add --size hint flag")
print("2. Use incremental shrinking during read (chunk by chunk)")
print("3. Profile with Instruments to find hidden allocations")
