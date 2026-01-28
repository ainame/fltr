import Collections

/// Manages chunks for efficient storage and retrieval
struct ChunkList: Sendable {
    private var chunks: [Chunk]
    private var cachedCount: Int = 0

    init() {
        self.chunks = []
    }

    var count: Int {
        cachedCount
    }

    var isEmpty: Bool {
        chunks.isEmpty
    }

    mutating func append(_ item: Item) {
        if chunks.isEmpty || chunks[chunks.count - 1].isFull {
            chunks.append(Chunk())
        }
        _ = chunks[chunks.count - 1].append(item)
        cachedCount += 1
    }

    func forEach(_ body: (Item) throws -> Void) rethrows {
        for chunk in chunks {
            for i in 0..<chunk.count {
                try body(chunk[i])
            }
        }
    }

    func map<T>(_ transform: (Item) throws -> T) rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for chunk in chunks {
            for i in 0..<chunk.count {
                result.append(try transform(chunk[i]))
            }
        }
        return result
    }

    subscript(index: Int) -> Item? {
        var remaining = index
        for chunk in chunks {
            if remaining < chunk.count {
                return chunk[remaining]
            }
            remaining -= chunk.count
        }
        return nil
    }
}
