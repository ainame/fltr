#!/usr/bin/env swift
import Foundation

// Verify actual struct sizes
print("=== Actual Swift Struct Sizes ===\n")

// Simulate the structures
struct Item {
    let index: Int32    // 4 bytes
    let offset: UInt32  // 4 bytes
    let length: UInt32  // 4 bytes
}

struct MatchResult {
    let score: Int      // 8 bytes
    let positions: [Int] // 16 bytes (Array header) + heap allocation
}

struct MatchedItem {
    let item: Item           // 12 bytes
    let matchResult: MatchResult  // 24+ bytes
    let points: UInt64       // 8 bytes
}

print("Item size: \(MemoryLayout<Item>.size) bytes (stride: \(MemoryLayout<Item>.stride))")
print("  index: \(MemoryLayout<Int32>.size) bytes")
print("  offset: \(MemoryLayout<UInt32>.size) bytes")
print("  length: \(MemoryLayout<UInt32>.size) bytes\n")

print("MatchResult size: \(MemoryLayout<MatchResult>.size) bytes (stride: \(MemoryLayout<MatchResult>.stride))")
print("  score: \(MemoryLayout<Int>.size) bytes")
print("  positions: \(MemoryLayout<[Int]>.size) bytes (array header only)")
print("  Note: positions array data is heap-allocated separately\n")

print("MatchedItem size: \(MemoryLayout<MatchedItem>.size) bytes (stride: \(MemoryLayout<MatchedItem>.stride))")
print("  This is the STACK size only")
print("  Heap allocations (positions array) are additional\n")

// Estimate heap overhead for positions array
print("=== Heap Allocation Overhead ===\n")
print("Swift Array heap allocation includes:")
print("  - malloc metadata: ~16 bytes")
print("  - Array storage header: ~16 bytes")
print("  - Element data: count × element size")
print("")
print("Examples:")
for count in [0, 3, 5, 10, 20] {
    let overhead = 32  // malloc + array header
    let data = count * 8  // Int64 on 64-bit platforms
    let total = overhead + data
    print("  \(count) positions: \(overhead) (overhead) + \(data) (data) = \(total) bytes")
}
print("")

print("=== MatchedItem Memory Footprint ===\n")
let stackSize = MemoryLayout<MatchedItem>.size
print("Stack: \(stackSize) bytes")
print("Heap (typical 5 positions): ~72 bytes")
print("Total per MatchedItem: ~\(stackSize + 72) bytes\n")

print("For 400,000 matched items:")
let count = 400_000
let totalBytes = count * (stackSize + 72)
print("  \(count) × \(stackSize + 72) bytes = \(totalBytes / 1_024 / 1_024) MB\n")

print("=== Array Container Overhead ===\n")
print("[[MatchedItem]] for partitions:")
print("  Outer array: 16 bytes")
print("  Each partition array: 32 bytes (malloc) + 16 bytes (Array header) = 48 bytes")
print("  With 10 partitions: 16 + 10 × 48 = ~500 bytes overhead")
print("  Plus the actual MatchedItem data\n")
