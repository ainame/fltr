import Foundation

/// Parallel matching engine using Swift structured concurrency
/// Note: Not an actor - matching is a pure computation that should not block input handling
struct MatchingEngine: Sendable {
    private let matcher: FuzzyMatcher
    private let parallelThreshold: Int  // Minimum items to use parallel matching
    let maxResults: Int  // Maximum results to keep (limits sorting overhead)

    init(matcher: FuzzyMatcher, parallelThreshold: Int = 1000, maxResults: Int = 10000) {
        self.matcher = matcher
        self.parallelThreshold = parallelThreshold
        self.maxResults = maxResults
    }

    /// Match items in parallel using TaskGroup
    /// This is a cancellable async operation that yields cooperatively
    func matchItemsParallel(pattern: String, items: [Item]) async -> [MatchedItem] {
        // Empty pattern - return all items quickly
        guard !pattern.isEmpty else {
            return items.map { MatchedItem(item: $0, matchResult: MatchResult(score: 0, positions: []), scheme: matcher.scheme) }
        }

        // NOTE: fzf always uses fuzzy matching - no substring fast path
        // But Swift is slower than Go, so we can optionally use substring for 1-char patterns
        // Set to 0 to match fzf exactly (always fuzzy), or 1-2 for faster short patterns
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
        let substringThreshold = 0  // 0 = pure fzf behavior (always fuzzy)
        let useExactMatch = substringThreshold > 0 && trimmedPattern.count <= substringThreshold && !trimmedPattern.contains(" ")

        if useExactMatch {
            return await exactSubstringMatch(pattern: trimmedPattern, items: items)
        }

        // Small dataset - use single-threaded with buffer reuse
        if items.count < parallelThreshold {
            return Utf8FuzzyMatch.$matrixBuffer.withValue(Utf8FuzzyMatch.MatrixBuffer()) {
                matcher.matchItems(pattern: pattern, items: items)
            }
        }

        // Parallel matching for large datasets
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let partitionSize = max(100, items.count / cpuCount)

        return await withTaskGroup(of: [MatchedItem].self) { group in
            // Partition items and dispatch to task group
            for partition in items.chunked(into: partitionSize) {
                group.addTask {
                    // Check for cancellation before processing partition
                    guard !Task.isCancelled else { return [] }

                    // Each task gets its own matrix buffer for reuse
                    return Utf8FuzzyMatch.$matrixBuffer.withValue(Utf8FuzzyMatch.MatrixBuffer()) {
                        var matched: [MatchedItem] = []
                        let scheme = self.matcher.scheme
                        for item in partition {
                            // Yield cooperatively every 100 items to allow cancellation
                            if matched.count % 100 == 0 {
                                guard !Task.isCancelled else { return [] }
                            }

                            if let result = self.matcher.match(pattern: pattern, text: item.text) {
                                matched.append(MatchedItem(item: item, matchResult: result, scheme: scheme))
                            }
                        }
                        return matched
                    }
                }
            }

            // Collect results from all tasks.
            // No early termination: cutting off partitions mid-flight produces
            // a non-deterministic subset that becomes the incremental base on
            // re-type, causing visible inconsistency.  topN() below is already
            // O(n + k log k), so collecting all matches first is cheap relative
            // to the matching work itself.
            var allMatches: [MatchedItem] = []
            allMatches.reserveCapacity(min(items.count, maxResults * 2))

            for await partitionResults in group {
                guard !Task.isCancelled else { break }
                allMatches.append(contentsOf: partitionResults)
            }

            // Limit and sort results for performance
            // With 800k items, "a" might match 200k - sorting that is O(n log n) = expensive!
            // Only keep top N results since UI can only display ~50 anyway
            if allMatches.count > maxResults {
                return topN(from: allMatches, count: maxResults)
            } else {
                allMatches.sort(by: rankLessThan)
                return allMatches
            }
        }
    }

    /// Fast exact substring matching for short patterns (fzf optimization)
    /// Much faster than fuzzy matching for 1-2 character patterns
    private func exactSubstringMatch(pattern: String, items: [Item]) async -> [MatchedItem] {
        let lowercasePattern = pattern.lowercased()

        // Parallel substring search
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let partitionSize = max(1000, items.count / cpuCount)

        return await withTaskGroup(of: [MatchedItem].self) { group in
            for partition in items.chunked(into: partitionSize) {
                group.addTask {
                    guard !Task.isCancelled else { return [] }

                    var matched: [MatchedItem] = []
                    let scheme = self.matcher.scheme
                    for item in partition {
                        // Fast case-insensitive substring check
                        if item.text.lowercased().contains(lowercasePattern) {
                            // Simple scoring: prefer matches at start, shorter strings
                            let position = item.text.lowercased().range(of: lowercasePattern)?.lowerBound.utf16Offset(in: item.text) ?? 0
                            let score = 1000 - position - item.text.count / 10

                            let positions = Array(position..<(position + pattern.count))
                            matched.append(MatchedItem(
                                item: item,
                                matchResult: MatchResult(score: score, positions: positions),
                                scheme: scheme
                            ))
                        }

                        // Cooperative cancellation
                        if matched.count % 100 == 0 {
                            guard !Task.isCancelled else { return [] }
                        }
                    }
                    return matched
                }
            }

            var allMatches: [MatchedItem] = []
            allMatches.reserveCapacity(min(items.count, maxResults * 2))

            for await partitionResults in group {
                guard !Task.isCancelled else { break }
                allMatches.append(contentsOf: partitionResults)
            }

            if allMatches.count > maxResults {
                return topN(from: allMatches, count: maxResults)
            } else {
                allMatches.sort(by: rankLessThan)
                return allMatches
            }
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
    func matchChunksParallel(pattern: String, chunkList: ChunkList, cache: ChunkCache) async -> [MatchedItem] {
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
            return all
        }

        let totalChunks = chunkList.chunkCount
        guard totalChunks > 0 else { return [] }

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
                        return partitionMatches
                    }
                }

                startIdx = endIdx
            }

            var allMatches: [MatchedItem] = []
            allMatches.reserveCapacity(min(chunkList.count, maxResults * 2))

            for await partitionResults in group {
                guard !Task.isCancelled else { break }
                allMatches.append(contentsOf: partitionResults)
            }

            if allMatches.count > maxResults {
                return topN(from: allMatches, count: maxResults)
            } else {
                allMatches.sort(by: rankLessThan)
                return allMatches
            }
        }
    }

    /// Select top N items by rank without fully sorting.
    /// Uses quickselect-style partitioning: O(n + k log k) instead of O(n log n).
    private func topN(from matches: [MatchedItem], count: Int) -> [MatchedItem] {
        guard matches.count > count else {
            return matches.sorted(by: rankLessThan)
        }

        var working = matches
        let k = count
        var left = 0
        var right = working.count - 1

        while left < right {
            let pivot = working[right]
            var i = left

            // Partition: move items that rank before (or equal to) pivot to the left
            for j in left..<right {
                if rankLessThan(working[j], pivot) || (!rankLessThan(pivot, working[j])) {
                    working.swapAt(i, j)
                    i += 1
                }
            }
            working.swapAt(i, right)

            if i == k {
                break
            } else if i > k {
                right = i - 1
            } else {
                left = i + 1
            }
        }

        var topK = Array(working.prefix(k))
        topK.sort(by: rankLessThan)
        return topK
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
