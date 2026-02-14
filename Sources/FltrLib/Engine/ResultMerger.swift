/// Lazy k-way merge of per-partition sorted results.
///
/// Mirrors fzf's Merger: each partition is sorted locally by its TaskGroup
/// task; items are materialised in global rank order on demand via ``get`` /
/// ``slice``.  ``count`` is available in O(1) without materialising anything —
/// this lets the status bar show the true match count without paying O(n log n)
/// sort cost for low-selectivity queries.
///
/// ### ChunkList-backed fast path
/// When the query is empty every item matches with score 0 and insertion order
/// *is* the rank order.  The ``chunkBacked`` case holds the ``ChunkList``
/// directly and returns ``MatchedItem`` views on demand — **zero** ``MatchedItem``
/// heap allocation for the entire input set.
enum ResultMerger: Sendable {
    /// Zero-allocation path for empty queries.  Items are enumerated in
    /// insertion order; ``MatchedItem`` wrappers are synthesised on the fly.
    case chunkBacked(ChunkList)

    /// Normal path: partitions produced by ``TaskGroup``, merged lazily.
    case partitionBacked(PartitionState)

    // ── stored state for the partition path ──────────────────────────────
    /// Mutable merge state.  Separated into its own struct so the enum case
    /// can hold it as a single associated value without boxing overhead.
    struct PartitionState: Sendable {
        let partitions:   [[MatchedItem]]
        var cursors:      [Int]
        var materialized: [MatchedItem]
        let count:        Int
    }

    // ── constructors ──────────────────────────────────────────────────────

    /// An empty merger (zero matches).
    static let empty = ResultMerger.partitionBacked(
        PartitionState(partitions: [], cursors: [], materialized: [], count: 0)
    )

    /// Wrap a ``ChunkList`` for the empty-query fast path.
    static func fromChunkList(_ cl: ChunkList) -> ResultMerger {
        .chunkBacked(cl)
    }

    /// Wrap partition arrays from a ``TaskGroup``.
    init(partitions: [[MatchedItem]]) {
        let count = partitions.reduce(0) { $0 + $1.count }
        self = .partitionBacked(
            PartitionState(partitions: partitions, cursors: [Int](repeating: 0, count: partitions.count),
                           materialized: [], count: count)
        )
    }

    // ── public interface ──────────────────────────────────────────────────

    /// Total number of matched items.
    var count: Int {
        switch self {
        case .chunkBacked(let cl):        return cl.count
        case .partitionBacked(let state): return state.count
        }
    }

    /// Return the item at global rank *idx*, materialising lazily.
    /// Returns nil when *idx* is out of range.
    mutating func get(_ idx: Int) -> MatchedItem? {
        switch self {
        case .chunkBacked(let cl):
            guard idx >= 0, idx < cl.count else { return nil }
            guard let item = cl[idx] else { return nil }
            return MatchedItem(item: item, score: 0, minBegin: 0,
                               points: MatchedItem.packPoints(0, UInt16(clamping: Int(item.length)), 0, UInt16.max))

        case .partitionBacked(var state):
            guard idx >= 0, idx < state.count else { return nil }
            state.materializeUpTo(idx)
            let result = state.materialized[idx]
            self = .partitionBacked(state)
            return result
        }
    }

    /// Return items in the half-open rank range [lo, hi), materialising lazily.
    mutating func slice(_ lo: Int, _ hi: Int) -> [MatchedItem] {
        let clampedLo = max(0, lo)
        let clampedHi = min(hi, count)
        guard clampedLo < clampedHi else { return [] }

        switch self {
        case .chunkBacked(let cl):
            var result = [MatchedItem]()
            result.reserveCapacity(clampedHi - clampedLo)
            for i in clampedLo..<clampedHi {
                if let item = cl[i] {
                    result.append(MatchedItem(item: item, score: 0, minBegin: 0,
                                             points: MatchedItem.packPoints(0, UInt16(clamping: Int(item.length)), 0, UInt16.max)))
                }
            }
            return result

        case .partitionBacked(var state):
            state.materializeUpTo(clampedHi - 1)
            let result = Array(state.materialized[clampedLo..<clampedHi])
            self = .partitionBacked(state)
            return result
        }
    }

    /// Flatten into a flat [Item] array (unsorted for partition path).
    /// O(n) — used as the candidate set for incremental filtering where
    /// re-matching will re-score and re-sort anyway.
    func allItems() -> [Item] {
        switch self {
        case .chunkBacked(let cl):
            var items = [Item]()
            items.reserveCapacity(cl.count)
            cl.forEach { items.append($0) }
            return items

        case .partitionBacked(let state):
            return state.partitions.flatMap { $0 }.map { $0.item }
        }
    }

    /// Return items whose item.index is in *indices*, sorted by index.
    /// O(n) scan — only called once on exit for multi-select.
    func selectedItems(indices: Set<Item.Index>) -> [Item] {
        switch self {
        case .chunkBacked(let cl):
            var result = [Item]()
            cl.forEach { item in
                if indices.contains(item.index) { result.append(item) }
            }
            return result.sorted { $0.index < $1.index }

        case .partitionBacked(let state):
            return state.partitions.flatMap { $0 }
                .filter { indices.contains($0.item.index) }
                .map { $0.item }
                .sorted { $0.index < $1.index }
        }
    }
}

// ── k-way merge (on PartitionState) ──────────────────────────────────────────
extension ResultMerger.PartitionState {
    mutating func materializeUpTo(_ idx: Int) {
        while materialized.count <= idx {
            var bestPartition = -1
            for i in 0..<partitions.count {
                guard cursors[i] < partitions[i].count else { continue }
                if bestPartition < 0 ||
                   rankLessThan(partitions[i][cursors[i]],
                                partitions[bestPartition][cursors[bestPartition]]) {
                    bestPartition = i
                }
            }
            guard bestPartition >= 0 else { break }
            materialized.append(partitions[bestPartition][cursors[bestPartition]])
            cursors[bestPartition] += 1
        }
    }
}
