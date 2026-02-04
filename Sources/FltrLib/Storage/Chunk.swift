import Collections

/// Shared sentinel buffer used only to fill the unused slots in a new Chunk.
/// Its bytes are never read; it exists solely to satisfy the value-type
/// initialiser requirement of InlineArray.
private let _sentinelBuffer = TextBuffer()

/// Fixed-size chunk for efficient storage
/// Based on fzf's chunk design (100 items per chunk)
///
/// Uses InlineArray (SE-0483) for zero heap allocation
/// Benefits: No heap allocation, better cache locality, no ARC overhead
struct Chunk: Sendable {
    static let capacity = 100
    private var storage: [100 of Item]
    private(set) var count: Int = 0

    init() {
        let dummy = Item(index: -1, buffer: _sentinelBuffer, offset: 0, length: 0)
        self.storage = .init(repeating: dummy)
    }

    var isFull: Bool {
        count >= Self.capacity
    }

    var items: [Item] {
        // Only return valid items (0..<count)
        (0..<count).map { storage[$0] }
    }

    /// Direct subscript access without array allocation
    subscript(index: Int) -> Item {
        get {
            precondition(index < count, "Index out of bounds")
            return storage[index]
        }
    }

    mutating func append(_ item: Item) -> Bool {
        guard !isFull else { return false }
        storage[count] = item
        count += 1
        return true
    }
}
