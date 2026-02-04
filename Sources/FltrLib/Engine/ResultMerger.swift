/// Lazy k-way merge of per-partition sorted results.
///
/// Mirrors fzf's Merger: each partition is sorted locally by its TaskGroup
/// task; items are materialised in global rank order on demand via ``get`` /
/// ``slice``.  ``count`` is available in O(1) without materialising anything —
/// this lets the status bar show the true match count without paying O(n log n)
/// sort cost for low-selectivity queries.
struct ResultMerger: Sendable {
    private let partitions: [[MatchedItem]]
    private var cursors: [Int]
    private var materialized: [MatchedItem]

    /// Total number of matched items across all partitions.
    let count: Int

    /// An empty merger (zero matches).
    static let empty = ResultMerger(partitions: [])

    init(partitions: [[MatchedItem]]) {
        self.partitions = partitions
        self.cursors = [Int](repeating: 0, count: partitions.count)
        self.materialized = []
        self.count = partitions.reduce(0) { $0 + $1.count }
    }

    /// Return the item at global rank *idx*, materialising lazily.
    /// Returns nil when *idx* is out of range.
    mutating func get(_ idx: Int) -> MatchedItem? {
        guard idx >= 0, idx < count else { return nil }
        materializeUpTo(idx)
        return materialized[idx]
    }

    /// Return items in the half-open rank range [lo, hi), materialising lazily.
    mutating func slice(_ lo: Int, _ hi: Int) -> [MatchedItem] {
        let clampedLo = max(0, lo)
        let clampedHi = min(hi, count)
        guard clampedLo < clampedHi else { return [] }
        materializeUpTo(clampedHi - 1)
        return Array(materialized[clampedLo..<clampedHi])
    }

    /// Flatten all partitions into a flat [Item] array (unsorted).
    /// O(n) — used as the candidate set for incremental filtering where
    /// re-matching will re-score and re-sort anyway.
    func allItems() -> [Item] {
        partitions.flatMap { $0 }.map { $0.item }
    }

    /// Return items whose item.index is in *indices*, sorted by index.
    /// O(n) scan — only called once on exit for multi-select.
    func selectedItems(indices: Set<Int>) -> [Item] {
        partitions.flatMap { $0 }
            .filter { indices.contains($0.item.index) }
            .map { $0.item }
            .sorted { $0.index < $1.index }
    }

    // MARK: - k-way merge

    private mutating func materializeUpTo(_ idx: Int) {
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
