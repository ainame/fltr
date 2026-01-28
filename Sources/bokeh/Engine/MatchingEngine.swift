import Foundation

/// Parallel matching engine using Swift structured concurrency
actor MatchingEngine {
    private let matcher: FuzzyMatcher
    private let parallelThreshold: Int  // Minimum items to use parallel matching

    init(matcher: FuzzyMatcher, parallelThreshold: Int = 1000) {
        self.matcher = matcher
        self.parallelThreshold = parallelThreshold
    }

    /// Match items in parallel using TaskGroup
    func matchItemsParallel(pattern: String, items: [Item]) async -> [MatchedItem] {
        // Empty pattern - return all items quickly
        guard !pattern.isEmpty else {
            return items.map { MatchedItem(item: $0, matchResult: MatchResult(score: 0, positions: [])) }
        }

        // Small dataset - use single-threaded
        if items.count < parallelThreshold {
            return matcher.matchItems(pattern: pattern, items: items)
        }

        // Parallel matching for large datasets
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let partitionSize = max(100, items.count / cpuCount)

        return await withTaskGroup(of: [MatchedItem].self) { group in
            // Partition items and dispatch to task group
            for partition in items.chunked(into: partitionSize) {
                group.addTask {
                    // Each task runs matcher independently
                    var matched: [MatchedItem] = []
                    for item in partition {
                        if let result = self.matcher.match(pattern: pattern, text: item.text) {
                            matched.append(MatchedItem(item: item, matchResult: result))
                        }
                    }
                    return matched
                }
            }

            // Collect results from all tasks
            var allMatches: [MatchedItem] = []
            for await partitionResults in group {
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
