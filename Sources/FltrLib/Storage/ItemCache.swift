import Foundation

/// Thread-safe storage for all items
actor ItemCache {
    private var chunkList = ChunkList()

    func append(_ text: String) {
        let index = chunkList.count
        let item = Item(index: index, text: text)
        chunkList.append(item)
    }

    func getAllItems() -> [Item] {
        chunkList.map { $0 }
    }

    func count() -> Int {
        chunkList.count
    }

    func isEmpty() -> Bool {
        chunkList.isEmpty
    }

    /// Return a value-type snapshot of the underlying ChunkList.
    /// Safe to send across actor boundaries — ChunkList is a Sendable struct
    /// and the snapshot is taken under actor isolation.
    func snapshotChunkList() -> ChunkList {
        chunkList
    }
}
