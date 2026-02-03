import Foundation

/// Per-chunk query-result cache.  Mirrors fzf's ChunkCache (cache.go).
///
/// ### Cache policy
/// - Only **full** chunks are cached.  The trailing partial chunk is always
///   re-scanned because its contents change as new items stream in.
/// - A result set is stored only when its count ≤ `queryCacheMax` (= 20).
///   Low-selectivity queries (e.g. typing a single common letter) match most
///   items in every chunk and are deliberately *not* cached — they provide no
///   narrowing benefit and would waste memory.
/// - On a cache miss, `search()` walks all prefixes and suffixes of the query
///   key (longest first) looking for a previously-cached narrower set.  When
///   found, only those items are re-matched against the new (more selective)
///   query.  This is the mechanism that makes keystroke 2+ fast.
///
/// ### Thread safety
/// Instances are shared across TaskGroup partitions.  All mutations go through
/// an NSLock.  The lock is never held across an await point.
final class ChunkCache: @unchecked Sendable {
    /// Maximum result count that will be cached per chunk.
    /// Mirrors fzf: queryCacheMax = chunkSize / 5 = 100 / 5 = 20.
    static let queryCacheMax = Chunk.capacity / 5   // 20

    private let lock = NSLock()

    /// chunkIndex → (queryString → [MatchedItem])
    private var cache: [Int: [String: [MatchedItem]]] = [:]

    // MARK: - Lookup

    /// Exact cache hit for (chunkIndex, query).
    /// Returns nil if the chunk is not full or the query has no cached entry.
    func lookup(chunkIndex: Int, chunkCount: Int, query: String) -> [MatchedItem]? {
        guard !query.isEmpty && chunkCount == Chunk.capacity else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cache[chunkIndex]?[query]
    }

    /// Prefix / suffix search.  Tries removing characters from the ends of the
    /// query, alternating prefix and suffix, longest sub-key first.  Returns
    /// the first cached hit — that set is guaranteed to be a superset of what
    /// the current (longer / different) query would produce, so it can be used
    /// as a narrowed candidate space for re-matching.
    ///
    /// Algorithm mirrors fzf cache.go:82-94.
    func search(chunkIndex: Int, chunkCount: Int, query: String) -> [MatchedItem]? {
        guard !query.isEmpty && chunkCount == Chunk.capacity else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let qc = cache[chunkIndex] else { return nil }

        for idx in 1..<query.count {
            // Try prefix (remove idx chars from the end)
            let prefixEnd = query.index(query.startIndex, offsetBy: query.count - idx)
            let prefix = String(query[query.startIndex..<prefixEnd])
            if let cached = qc[prefix] { return cached }

            // Try suffix (remove idx chars from the start)
            let suffixStart = query.index(query.startIndex, offsetBy: idx)
            let suffix = String(query[suffixStart...])
            if let cached = qc[suffix] { return cached }
        }
        return nil
    }

    // MARK: - Store

    /// Add a result set to the cache.  Silently drops the write if the chunk
    /// is not full or the result count exceeds `queryCacheMax`.
    func add(chunkIndex: Int, chunkCount: Int, query: String, results: [MatchedItem]) {
        guard !query.isEmpty
            && chunkCount == Chunk.capacity
            && results.count <= Self.queryCacheMax
        else { return }

        lock.lock()
        defer { lock.unlock() }
        if cache[chunkIndex] == nil {
            cache[chunkIndex] = [:]
        }
        cache[chunkIndex]![query] = results
    }

    // MARK: - Invalidation

    /// Drop all cached data.  Called whenever the item list grows (new chunk
    /// appended or existing chunks may have shifted).
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll(keepingCapacity: true)
    }
}
