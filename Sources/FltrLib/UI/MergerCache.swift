/// Single-entry result cache keyed on (pattern, itemCount).
///
/// Mirrors fzf's mergerCache.  Invalidated whenever the item set grows.
/// Only stores results whose count is ≤ `maxResults` — low-selectivity
/// queries (e.g. a single character on 800 k items) are deliberately
/// excluded to avoid holding large arrays with little reuse benefit.
struct MergerCache {
    private var pattern:   String       = ""
    private var results:   ResultMerger = .empty
    private var itemCount: Int          = 0

    /// Gate: result sets larger than this are never cached.
    static let maxResults = 100_000

    /// Return cached results when both pattern and item-count match.
    func lookup(pattern: String, itemCount: Int) -> ResultMerger? {
        guard pattern == self.pattern && itemCount == self.itemCount else { return nil }
        return results
    }

    /// Store results.  Silently drops the write when the result set is too
    /// large to be worth caching.
    mutating func store(pattern: String, itemCount: Int, results: ResultMerger) {
        guard results.count <= Self.maxResults else { return }
        self.pattern   = pattern
        self.results   = results
        self.itemCount = itemCount
    }

    /// Drop the cached entry (called whenever the live item set changes).
    mutating func invalidate() {
        pattern   = ""
        results   = .empty
        itemCount = 0
    }
}
