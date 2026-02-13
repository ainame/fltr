#!/usr/bin/env swift
import Foundation

// Demonstrate array shrinking benefit
print("=== Array Growth Overhead Test ===\n")

// Simulate building a large array through growth
func buildWithGrowth(count: Int) -> [Int] {
    var arr: [Int] = []
    for i in 0..<count {
        arr.append(i)
    }
    return arr
}

func buildWithReservation(count: Int) -> [Int] {
    var arr: [Int] = []
    arr.reserveCapacity(count)
    for i in 0..<count {
        arr.append(i)
    }
    return arr
}

func buildAndShrink(count: Int) -> [Int] {
    var arr: [Int] = []
    for i in 0..<count {
        arr.append(i)
    }
    // Shrink: create new array with exact capacity
    return Array(arr)
}

for count in [10_000, 50_000, 100_000] {
    print("Array with \(count) elements:")

    let grown = buildWithGrowth(count: count)
    print("  With growth: capacity = \(grown.capacity), count = \(grown.count)")
    let grownOverhead = (grown.capacity - grown.count) * 8
    print("  Overhead: \((grown.capacity - grown.count)) elements = \(grownOverhead / 1024) KB")

    let reserved = buildWithReservation(count: count)
    print("  With reservation: capacity = \(reserved.capacity), count = \(reserved.count)")
    let reservedOverhead = (reserved.capacity - reserved.count) * 8
    print("  Overhead: \((reserved.capacity - reserved.count)) elements = \(reservedOverhead / 1024) KB")

    let shrunk = buildAndShrink(count: count)
    print("  After shrink: capacity = \(shrunk.capacity), count = \(shrunk.count)")
    let shrunkOverhead = (shrunk.capacity - shrunk.count) * 8
    print("  Overhead: \((shrunk.capacity - shrunk.count)) elements = \(shrunkOverhead / 1024) KB")

    print("")
}

// Simulate MatchedItem arrays (112 bytes each)
print("=== Partition Array Overhead (MatchedItem = 112 bytes) ===\n")

struct MockMatchedItem {
    let data: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
               UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)  // ~112 bytes
}

func buildMatchedItems(count: Int) -> [MockMatchedItem] {
    var arr: [MockMatchedItem] = []
    let item = MockMatchedItem(data: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    for _ in 0..<count {
        arr.append(item)
    }
    return arr
}

let partitionSize = 82_770  // 827,707 items / 10 partitions
print("Partition size: \(partitionSize) items")

let partition = buildMatchedItems(count: partitionSize)
print("Capacity: \(partition.capacity)")
print("Count: \(partition.count)")
let overhead = (partition.capacity - partition.count) * 112
print("Overhead: \((partition.capacity - partition.count)) items × 112 bytes = \(overhead / 1024 / 1024) MB")

print("")
print("With 10 partitions:")
let totalOverhead = overhead * 10
print("Total overhead: \(totalOverhead / 1024 / 1024) MB")

let shrunkPartition = Array(partition)
print("\nAfter shrink:")
print("Capacity: \(shrunkPartition.capacity)")
let shrunkOverhead = (shrunkPartition.capacity - shrunkPartition.count) * 112
print("Overhead: \((shrunkPartition.capacity - shrunkPartition.count)) items × 112 bytes = \(shrunkOverhead / 1024 / 1024) MB")

print("\n=== Summary ===")
print("Expected savings from shrinking 10 partitions: \((totalOverhead - shrunkOverhead * 10) / 1024 / 1024) MB")
