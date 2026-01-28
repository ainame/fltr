import Collections

/// Manages chunks for efficient storage and retrieval
struct ChunkList: Sendable {
    private var chunks: [Chunk]

    init() {
        self.chunks = []
    }

    var count: Int {
        chunks.reduce(0) { $0 + $1.count }
    }

    var isEmpty: Bool {
        chunks.isEmpty
    }

    mutating func append(_ item: Item) {
        if chunks.isEmpty || chunks[chunks.count - 1].isFull {
            chunks.append(Chunk())
        }
        _ = chunks[chunks.count - 1].append(item)
    }

    func forEach(_ body: (Item) throws -> Void) rethrows {
        for chunk in chunks {
            for item in chunk.items {
                try body(item)
            }
        }
    }

    func map<T>(_ transform: (Item) throws -> T) rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for chunk in chunks {
            for item in chunk.items {
                result.append(try transform(item))
            }
        }
        return result
    }

    subscript(index: Int) -> Item? {
        var remaining = index
        for chunk in chunks {
            if remaining < chunk.count {
                return chunk.items[remaining]
            }
            remaining -= chunk.count
        }
        return nil
    }
}
