#!/usr/bin/env swift
import Foundation

print("=== Investigating .map { $0 } Memory Behavior ===\n")

// Test 1: Does map copy for value types?
print("Test 1: UInt8 array (value type)")
var bytes = [UInt8](repeating: 0, count: 10_000_000)  // 10 MB
print("Initial capacity: \(bytes.capacity)")
print("After growing by append:")
for _ in 0..<1000 {
    bytes.append(42)
}
print("  Capacity: \(bytes.capacity), count: \(bytes.count)")

print("\nApplying map { $0 }...")
bytes = bytes.map { $0 }
print("  Capacity: \(bytes.capacity), count: \(bytes.count)")

// Test 2: Does map help at all for shrinking?
print("\n\nTest 2: Build array with growth, then shrink")
var growing = [UInt8]()
for i in 0..<10_000_000 {
    growing.append(UInt8(i % 256))
}
print("After growth: capacity = \(growing.capacity), count = \(growing.count)")
let overhead = growing.capacity - growing.count
print("  Overhead: \(overhead) bytes (\(overhead * 100 / growing.count)%)")

growing = growing.map { $0 }
print("After map: capacity = \(growing.capacity), count = \(growing.count)")
let newOverhead = growing.capacity - growing.count
print("  Overhead: \(newOverhead) bytes (\(newOverhead * 100 / growing.count)%)")

// Test 3: Alternative approaches
print("\n\nTest 3: Alternative shrinking methods")
var test = [UInt8]()
for i in 0..<1_000_000 {
    test.append(UInt8(i % 256))
}
print("Original: capacity = \(test.capacity)")

// Method 1: Manual copy with reserveCapacity
do {
    var shrunk = [UInt8]()
    shrunk.reserveCapacity(test.count)
    for byte in test {
        shrunk.append(byte)
    }
    print("Manual copy: capacity = \(shrunk.capacity)")
}

// Method 2: Array(unsafeUninitializedCapacity:)
do {
    let shrunk = Array<UInt8>(unsafeUninitializedCapacity: test.count) { buffer, initializedCount in
        _ = buffer.initialize(from: test)
        initializedCount = test.count
    }
    print("unsafeUninitializedCapacity: capacity = \(shrunk.capacity)")
}

print("\n=== Conclusion ===")
print("map { $0 } does shrink capacity, but it COPIES all elements.")
print("For large arrays (10 MB+), this temporarily DOUBLES memory usage.")
print("The old array is only freed after map completes and ARC runs.")
print("\nFor memory-constrained scenarios:")
print("- Keep TextBuffer/ChunkStore shrinking (one-time, after stdin)")
print("- AVOID shrinking hot-path arrays (partition results)")
print("- Use reserveCapacity upfront instead of shrinking later")
