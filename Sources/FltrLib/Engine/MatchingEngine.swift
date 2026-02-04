import Foundation

/// Parallel matching engine using Swift structured concurrency
/// Note: Not an actor - matching is a pure computation that should not block input handling
struct MatchingEngine: Sendable {
    private let matcher: FuzzyMatcher
    private let parallelThreshold: Int  // Minimum items to use parallel matching

    init(matcher: FuzzyMatcher, parallelThreshold: Int = 1000) {
        self.matcher = matcher
        self.parallelThreshold = parallelThreshold
    }

    /// Match items in parallel using TaskGroup.
    /// Each partition is sorted locally; the caller merges lazily via ResultMerger.
    func matchItemsParallel(pattern: String, items: [Item]) async -> ResultMerger {
        guard !pattern.isEmpty else {
            // Single partition, already in insertion order (= rank order for score-0 items)
            let all = items.map { MatchedItem(item: $0, matchResult: MatchResult(score: 0, positions: []), scheme: matcher.scheme) }
            return ResultMerger(partitions: [all])
        }

        // Small dataset - use single-threaded with buffer reuse
        if items.count < parallelThreshold {
            // matchItems already sorts by rankLessThan
            let results = Utf8FuzzyMatch.$matrixBuffer.withValue(Utf8FuzzyMatch.MatrixBuffer()) {
                matcher.matchItems(pattern: pattern, items: items)
            }
            return ResultMerger(partitions: [results])
        }

        // Parallel matching for large datasets
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let partitionSize = max(100, items.count / cpuCount)

        return await withTaskGroup(of: [MatchedItem].self) { group in
            for partition in items.chunked(into: partitionSize) {
                group.addTask {
                    guard !Task.isCancelled else { return [] }

                    return Utf8FuzzyMatch.$matrixBuffer.withValue(Utf8FuzzyMatch.MatrixBuffer()) {
                        var matched: [MatchedItem] = []
                        let scheme = self.matcher.scheme
                        for item in partition {
                            if matched.count % 100 == 0 {
                                guard !Task.isCancelled else { return [] }
                            }
                            if let result = self.matcher.match(pattern: pattern, text: item.text) {
                                matched.append(MatchedItem(item: item, matchResult: result, scheme: scheme))
                            }
                        }
                        // Sort this partition locally — the Merger does the global interleave
                        matched.sort(by: rankLessThan)
                        return matched
                    }
                }
            }

            var partitions = [[MatchedItem]]()
            for await partitionResults in group {
                guard !Task.isCancelled else { break }
                if !partitionResults.isEmpty {
                    partitions.append(partitionResults)
                }
            }
            return ResultMerger(partitions: partitions)
        }
    }

    /// Fast exact substring matching for short patterns (fzf optimization)
    /// Much faster than fuzzy matching for 1-2 character patterns
    private func exactSubstringMatch(pattern: String, items: [Item]) async -> ResultMerger {
        let lowercasePattern = pattern.lowercased()

        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let partitionSize = max(1000, items.count / cpuCount)

        return await withTaskGroup(of: [MatchedItem].self) { group in
            for partition in items.chunked(into: partitionSize) {
                group.addTask {
                    guard !Task.isCancelled else { return [] }

                    var matched: [MatchedItem] = []
                    let scheme = self.matcher.scheme
                    for item in partition {
                        if item.text.lowercased().contains(lowercasePattern) {
                            let position = item.text.lowercased().range(of: lowercasePattern)?.lowerBound.utf16Offset(in: item.text) ?? 0
                            let score = 1000 - position - item.text.count / 10
                            let positions = Array(position..<(position + pattern.count))
                            matched.append(MatchedItem(
                                item: item,
                                matchResult: MatchResult(score: score, positions: positions),
                                scheme: scheme
                            ))
                        }
                        if matched.count % 100 == 0 {
                            guard !Task.isCancelled else { return [] }
                        }
                    }
                    matched.sort(by: rankLessThan)
                    return matched
                }
            }

            var partitions = [[MatchedItem]]()
            for await partitionResults in group {
                guard !Task.isCancelled else { break }
                if !partitionResults.isEmpty {
                    partitions.append(partitionResults)
                }
            }
            return ResultMerger(partitions: partitions)
        }
    }

    // MARK: - Chunk-parallel matching with per-chunk cache

    /// Match items by iterating the ChunkList chunk-by-chunk, consulting the
    /// ChunkCache at each step.  Per-chunk flow:
    ///   1. Exact cache hit  → return cached results (zero matching work).
    ///   2. Search hit       → re-match only the cached subset (narrowed).
    ///   3. Full miss        → match every item in the chunk.
    ///   4. Store result if selectivity gate passes (count ≤ queryCacheMax).
    ///
    /// Parallelisation and topN / cancellation logic mirrors
    /// ``matchItemsParallel``.
    func matchChunksParallel(pattern: String, chunkList: ChunkList, cache: ChunkCache) async -> ResultMerger {
        guard !pattern.isEmpty else {
            var all: [MatchedItem] = []
            all.reserveCapacity(chunkList.count)
            let scheme = matcher.scheme
            for ci in 0..<chunkList.chunkCount {
                let chunk = chunkList.chunk(at: ci)
                for i in 0..<chunk.count {
                    all.append(MatchedItem(item: chunk[i], matchResult: MatchResult(score: 0, positions: []), scheme: scheme))
                }
            }
            // Single partition, already in insertion order (= rank order for score-0 items)
            return ResultMerger(partitions: [all])
        }

        let totalChunks = chunkList.chunkCount
        guard totalChunks > 0 else { return .empty }

        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let chunksPerPartition = max(1, totalChunks / cpuCount)

        return await withTaskGroup(of: [MatchedItem].self) { group in
            var startIdx = 0
            while startIdx < totalChunks {
                let endIdx = min(startIdx + chunksPerPartition, totalChunks)
                let partitionStart = startIdx
                let partitionEnd   = endIdx

                group.addTask {
                    guard !Task.isCancelled else { return [] }

                    return Utf8FuzzyMatch.$matrixBuffer.withValue(Utf8FuzzyMatch.MatrixBuffer()) {
                        var partitionMatches: [MatchedItem] = []
                        let scheme = self.matcher.scheme

                        for ci in partitionStart..<partitionEnd {
                            guard !Task.isCancelled else { return [] }

                            let chunk = chunkList.chunk(at: ci)

                            // 1. Exact cache hit — zero matching work
                            if let cached = cache.lookup(chunkIndex: ci, chunkCount: chunk.count, query: pattern) {
                                partitionMatches.append(contentsOf: cached)
                                continue
                            }

                            // 2. Search hit — narrow the candidate set
                            let candidates = cache.search(chunkIndex: ci, chunkCount: chunk.count, query: pattern)

                            var chunkResults: [MatchedItem] = []

                            if let candidates = candidates {
                                for candidate in candidates {
                                    if let result = self.matcher.match(pattern: pattern, text: candidate.item.text) {
                                        chunkResults.append(MatchedItem(item: candidate.item, matchResult: result, scheme: scheme))
                                    }
                                }
                            } else {
                                // 3. Full miss — match every item in the chunk
                                for i in 0..<chunk.count {
                                    let item = chunk[i]
                                    if let result = self.matcher.match(pattern: pattern, text: item.text) {
                                        chunkResults.append(MatchedItem(item: item, matchResult: result, scheme: scheme))
                                    }
                                }
                            }

                            // 4. Store if selectivity gate passes
                            cache.add(chunkIndex: ci, chunkCount: chunk.count, query: pattern, results: chunkResults)

                            partitionMatches.append(contentsOf: chunkResults)
                        }
                        // Sort this partition locally — the Merger does the global interleave
                        partitionMatches.sort(by: rankLessThan)
                        return partitionMatches
                    }
                }

                startIdx = endIdx
            }

            var partitions = [[MatchedItem]]()
            for await partitionResults in group {
                guard !Task.isCancelled else { break }
                if !partitionResults.isEmpty {
                    partitions.append(partitionResults)
                }
            }
            return ResultMerger(partitions: partitions)
        }
    }

}

// Helper extension for chunking arrays
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
