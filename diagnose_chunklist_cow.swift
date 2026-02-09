#!/usr/bin/env swift
import Foundation

// Test if ChunkList CoW is working correctly

struct MockChunk {
    let id: Int
}

class MockChunkStore {
    var frozen: [MockChunk] = []
    var tail: MockChunk = MockChunk(id: -1)

    func append(_ chunk: MockChunk) {
        frozen.append(chunk)
    }

    func snapshot() -> MockChunkList {
        MockChunkList(frozen: frozen, tailSnapshot: tail)
    }
}

struct MockChunkList {
    private let frozen: [MockChunk]
    private let tailSnapshot: MockChunk

    init(frozen: [MockChunk], tailSnapshot: MockChunk) {
        self.frozen = frozen
        self.tailSnapshot = tailSnapshot
    }
}

print("=== Testing ChunkList CoW Behavior ===\n")

let store = MockChunkStore()

// Add 8278 chunks
for i in 0..<8278 {
    store.append(MockChunk(id: i))
}

print("Store has \(store.frozen.count) chunks")
print("Store frozen.capacity: \(store.frozen.capacity)\n")

// Take multiple snapshots
var snapshots: [MockChunkList] = []
for i in 1...5 {
    snapshots.append(store.snapshot())
    print("Snapshot \(i) created")
}

print("\nMemory test:")
print("- Store array capacity: \(store.frozen.capacity)")
print("- Each snapshot holds a reference to frozen array")
print("- With CoW, all snapshots share the SAME backing storage")
print("- Total memory: ~1 copy of the array (until store modifies it)")
print("")
print("If snapshots hold SEPARATE copies:")
print("- That would be 5 × \(store.frozen.capacity) × ~1200 bytes")
print("- = \((store.frozen.capacity * 1200 * 5) / 1024 / 1024) MB")
print("")
print("HYPOTHESIS: Multiple ChunkList snapshots are NOT the issue")
print("unless there's a bug preventing CoW sharing.")
print("")
print("===More likely culprits===")
print("1. ResultMerger.partitionBacked holding large MatchedItem arrays")
print("2. Multiple TextBuffer references/copies")
print("3. Hidden String allocations despite optimization")
print("4. Swift runtime overhead larger than expected")
print("5. Debug info or other metadata")
