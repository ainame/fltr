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
}
