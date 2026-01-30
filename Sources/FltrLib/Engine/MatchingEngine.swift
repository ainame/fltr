import Foundation

/// Parallel matching engine using Swift structured concurrency
/// Note: Not an actor - matching is a pure computation that should not block input handling
struct MatchingEngine: Sendable {
    private let matcher: FuzzyMatcher
    private let parallelThreshold: Int  // Minimum items to use parallel matching
    private let maxResults: Int  // Maximum results to keep (limits sorting overhead)

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
            return items.map { MatchedItem(item: $0, matchResult: MatchResult(score: 0, positions: [])) }
        }

        // Small dataset - use single-threaded with buffer reuse
        if items.count < parallelThreshold {
            return FuzzyMatchV2.$matrixBuffer.withValue(FuzzyMatchV2.MatrixBuffer()) {
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
                    return FuzzyMatchV2.$matrixBuffer.withValue(FuzzyMatchV2.MatrixBuffer()) {
                        var matched: [MatchedItem] = []
                        for item in partition {
                            // Yield cooperatively every 100 items to allow cancellation
                            if matched.count % 100 == 0 {
                                guard !Task.isCancelled else { return [] }
                            }

                            if let result = self.matcher.match(pattern: pattern, text: item.text) {
                                matched.append(MatchedItem(item: item, matchResult: result))
                            }
                        }
                        return matched
                    }
                }
            }

            // Collect results from all tasks with early termination
            var allMatches: [MatchedItem] = []
            // Reserve capacity for better performance
            allMatches.reserveCapacity(min(items.count, maxResults * 2))

            for await partitionResults in group {
                // Check cancellation while collecting results
                guard !Task.isCancelled else { break }
                allMatches.append(contentsOf: partitionResults)

                // Aggressive early termination: stop as soon as we have enough candidates
                // We need some buffer (1.5x) because we haven't sorted yet
                if allMatches.count >= maxResults + (maxResults / 2) {
                    group.cancelAll()
                    break
                }
            }

            // Limit and sort results for performance
            // With 800k items, "a" might match 200k - sorting that is O(n log n) = expensive!
            // Only keep top N results since UI can only display ~50 anyway
            if allMatches.count > maxResults {
                // Use partial sort for better performance: O(n + k log k) instead of O(n log n)
                // where k = maxResults and n = total matches
                return topN(from: allMatches, count: maxResults)
            } else {
                // Small result set - just sort normally
                allMatches.sort { $0.matchResult.score > $1.matchResult.score }
                return allMatches
            }
        }
    }

    /// Select top N items by score without fully sorting
    /// Uses partial sort: O(n + k log k) instead of O(n log n)
    /// where n = input size, k = count
    private func topN(from matches: [MatchedItem], count: Int) -> [MatchedItem] {
        guard matches.count > count else {
            return matches.sorted { $0.matchResult.score > $1.matchResult.score }
        }

        // Use nth_element approach: partition around kth element
        var working = matches

        // Find the kth largest score using quickselect-style partitioning
        // This moves top k elements to the front (unsorted)
        let k = count
        var left = 0
        var right = working.count - 1

        while left < right {
            let pivotScore = working[right].matchResult.score
            var i = left

            // Partition: move items >= pivot to the left
            for j in left..<right {
                if working[j].matchResult.score >= pivotScore {
                    working.swapAt(i, j)
                    i += 1
                }
            }
            working.swapAt(i, right)

            // Check if we found the kth position
            if i == k {
                break
            } else if i > k {
                right = i - 1
            } else {
                left = i + 1
            }
        }

        // Take top k and sort them
        var topK = Array(working.prefix(k))
        topK.sort { $0.matchResult.score > $1.matchResult.score }
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
