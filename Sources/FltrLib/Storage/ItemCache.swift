/// Thread-safe storage for all items.
///
/// Owns the single ``TextBuffer`` that backs every ``Item``.  Text is appended
/// into that buffer first; only then is the ``Item`` (with its offset window)
/// created and stored in the ``ChunkList``.  This ordering guarantees that any
/// ``Item`` that has escaped the actor already has valid bytes behind it.
actor ItemCache {
    private var chunkList = ChunkList()
    let buffer = TextBuffer()

    func append(_ text: String) {
        let index = chunkList.count
        let (offset, length) = buffer.append(text)
        let item = Item(index: index, buffer: buffer, offset: offset, length: length)
        chunkList.append(item)
    }

    /// Register an already-appended byte range as a new Item in the ChunkList.
    /// The caller must have appended the bytes to ``buffer`` *before* this call;
    /// this ordering guarantees any Item that escapes the actor has valid backing bytes.
    func registerItem(offset: UInt32, length: UInt32) {
        let index = chunkList.count
        let item = Item(index: index, buffer: buffer, offset: offset, length: length)
        chunkList.append(item)
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
