import Collections

/// Fixed-size chunk for efficient storage
/// Based on fzf's chunk design (100 items per chunk)
struct Chunk: Sendable {
    static let capacity = 100
    private(set) var items: [Item]

    init() {
        self.items = []
        self.items.reserveCapacity(Self.capacity)
    }

    var isFull: Bool {
        items.count >= Self.capacity
    }

    var count: Int {
        items.count
    }

    mutating func append(_ item: Item) -> Bool {
        guard !isFull else { return false }
        items.append(item)
        return true
    }
}
