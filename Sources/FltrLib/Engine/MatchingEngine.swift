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
    ///
    /// *items* is a flat ``[Item]`` — used on the incremental-filter path where the
    /// candidate set was extracted from a previous merger.  All Items share the same
    /// ``TextBuffer``, so each task opens it independently via ``withBytes``.
    func matchItemsParallel(pattern: String, items: [Item]) async -> ResultMerger {
        guard !pattern.isEmpty else {
            // For the flat-item path we cannot avoid wrapping because the caller
            // expects a partition-backed merger it can re-score later.  But this
            // path only fires on incremental filter (previous results ≪ total),
            // so the allocation is small.
            let all = items.map { MatchedItem(item: $0, matchResult: MatchResult(score: 0, positions: [])) }
            return ResultMerger(partitions: [all])
        }

        // Small dataset - use single-threaded with buffer reuse
        if items.count < parallelThreshold {
            guard let buf = items.first?.buffer else { return .empty }
            let results = buf.withBytes { allBytes in
                Utf8FuzzyMatch.$matrixBuffer.withValue(Utf8FuzzyMatch.MatrixBuffer()) {
                    matchItemsFromBuffer(pattern: pattern, items: items, allBytes: allBytes)
                }
            }
            return ResultMerger(partitions: [results])
        }

        // Parallel matching for large datasets
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let partitionSize = max(100, items.count / cpuCount)
        guard let buf = items.first?.buffer else { return .empty }

        return await withTaskGroup(of: [MatchedItem].self) { group in
            for partition in items.chunked(into: partitionSize) {
                group.addTask {
                    guard !Task.isCancelled else { return [] }

                    return buf.withBytes { allBytes in
                        Utf8FuzzyMatch.$matrixBuffer.withValue(Utf8FuzzyMatch.MatrixBuffer()) {
                            self.matchItemsFromBuffer(pattern: pattern, items: partition, allBytes: allBytes)
                        }
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

    // MARK: - Chunk-parallel matching with per-chunk cache

    /// Match items by iterating the ChunkList chunk-by-chunk, consulting the
    /// ChunkCache at each step.  Per-chunk flow:
    ///   1. Exact cache hit  → return cached results (zero matching work).
    ///   2. Search hit       → re-match only the cached subset (narrowed).
    ///   3. Full miss        → match every item in the chunk.
    ///   4. Store result if selectivity gate passes (count ≤ queryCacheMax).
    ///
    /// Parallelisation and cancellation logic mirrors ``matchItemsParallel``.
    func matchChunksParallel(pattern: String, chunkList: ChunkList, cache: ChunkCache) async -> ResultMerger {
        guard !pattern.isEmpty else {
            // Zero-allocation fast path: ChunkList in insertion order IS rank order.
            return .fromChunkList(chunkList)
        }

        let totalChunks = chunkList.chunkCount
        guard totalChunks > 0 else { return .empty }

        // All items share the same TextBuffer — grab it from the first chunk.
        guard chunkList.chunk(at: 0).count > 0 else { return .empty }
        let buffer = chunkList.chunk(at: 0)[0].buffer

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

                    return buffer.withBytes { allBytes in
                        Utf8FuzzyMatch.$matrixBuffer.withValue(Utf8FuzzyMatch.MatrixBuffer()) {
                            var partitionMatches: [MatchedItem] = []

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
                                        let item = candidate.item
                                        let slice = UnsafeBufferPointer(
                                            start: allBytes.baseAddress! + Int(item.offset),
                                            count: Int(item.length)
                                        )
                                        if let result = self.matcher.match(pattern: pattern, textBuf: slice) {
                                            chunkResults.append(MatchedItem(item: item, matchResult: result))
                                        }
                                    }
                                } else {
                                    // 3. Full miss — match every item in the chunk
                                    for i in 0..<chunk.count {
                                        let item = chunk[i]
                                        let slice = UnsafeBufferPointer(
                                            start: allBytes.baseAddress! + Int(item.offset),
                                            count: Int(item.length)
                                        )
                                        if let result = self.matcher.match(pattern: pattern, textBuf: slice) {
                                            chunkResults.append(MatchedItem(item: item, matchResult: result))
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

    // MARK: - Private helpers

    /// Match a slice of items using a pre-opened buffer pointer.
    /// Caller must hold the buffer pointer alive for the duration.
    private func matchItemsFromBuffer(pattern: String, items: [Item], allBytes: UnsafeBufferPointer<UInt8>) -> [MatchedItem] {
        var matched: [MatchedItem] = []
        for item in items {
            if matched.count % 100 == 0 {
                guard !Task.isCancelled else { return [] }
            }
            let slice = UnsafeBufferPointer(
                start: allBytes.baseAddress! + Int(item.offset),
                count: Int(item.length)
            )
            if let result = matcher.match(pattern: pattern, textBuf: slice) {
                matched.append(MatchedItem(item: item, matchResult: result))
            }
        }
        matched.sort(by: rankLessThan)
        return matched
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
