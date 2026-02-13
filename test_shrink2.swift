#!/usr/bin/env swift
import Foundation

print("=== Testing Array Shrink Methods ===\n")

func testShrinkMethod(_ name: String, _ shrink: ([Int]) -> [Int]) {
    var arr: [Int] = []
    for i in 0..<100_000 {
        arr.append(i)
    }
    print("\(name):")
    print("  Before: capacity = \(arr.capacity), count = \(arr.count)")
    let shrunk = shrink(arr)
    print("  After:  capacity = \(shrunk.capacity), count = \(shrunk.count)")
    print("  Saved:  \((arr.capacity - shrunk.capacity) * 8 / 1024) KB\n")
}

// Method 1: Array(_:) constructor
testShrinkMethod("Array(_:) constructor") { arr in
    Array(arr)
}

// Method 2: map identity
testShrinkMethod("map identity") { arr in
    arr.map { $0 }
}

// Method 3: Array.init with sequence
testShrinkMethod("Array(arr[...])") { arr in
    Array(arr[...])
}

// Method 4: reserveCapacity + append (manual)
testShrinkMethod("Manual reserveCapacity + append") { arr in
    var result = [Int]()
    result.reserveCapacity(arr.count)
    for item in arr {
        result.append(item)
    }
    return result
}

// Method 5: Array.init(repeating:count:) then mutate
testShrinkMethod("Pre-allocated with repeating") { arr in
    var result = Array(repeating: 0, count: arr.count)
    for i in 0..<arr.count {
        result[i] = arr[i]
    }
    return result
}

print("=== Recommendation ===")
print("Swift doesn't provide a built-in shrinkToFit() for Arrays.")
print("The TextBuffer.shrinkToFit() uses Array(_:) which may not actually shrink.")
print("\nBest options:")
print("1. Don't rely on shrinking - instead, use reserveCapacity upfront")
print("2. For truly shrinking: arr.map { $0 } or manual pre-allocated copy")
