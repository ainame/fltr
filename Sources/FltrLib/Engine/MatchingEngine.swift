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

            // Collect results from all tasks
            var allMatches: [MatchedItem] = []
            for await partitionResults in group {
                // Check cancellation while collecting results
                guard !Task.isCancelled else { break }
                allMatches.append(contentsOf: partitionResults)
            }

            // Sort by score (descending)
            allMatches.sort { $0.matchResult.score > $1.matchResult.score }
            return allMatches
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
