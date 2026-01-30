import FltrLib

// Test that top-N actually limits results
let matcher = FuzzyMatcher()
let engine = MatchingEngine(matcher: matcher, maxResults: 100)

// Create 10k test items
let items = (0..<10000).map { Item(index: $0, text: "item_\($0)_test") }

Task {
    let results = await engine.matchItemsParallel(pattern: "item", items: items)
    print("Pattern 'item' matched \(results.count) items (should be <= 100)")
    
    let results2 = await engine.matchItemsParallel(pattern: "xyz", items: items)
    print("Pattern 'xyz' matched \(results2.count) items")
}

try await Task.sleep(for: .seconds(2))
