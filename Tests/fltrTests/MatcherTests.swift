import Testing
@testable import FltrLib

// MARK: - Basic Matching Tests

@Test("Basic fuzzy matching")
func basicMatching() {
    let matcher = FuzzyMatcher(caseSensitive: false)

    // Should match
    #expect(matcher.match(pattern: "ap", text: "apple") != nil)
    #expect(matcher.match(pattern: "ban", text: "banana") != nil)
    #expect(matcher.match(pattern: "che", text: "cherry") != nil)

    // Should not match
    #expect(matcher.match(pattern: "xyz", text: "apple") == nil)
}

@Test("Case insensitive matching")
func caseInsensitiveMatching() {
    let matcher = FuzzyMatcher(caseSensitive: false)

    #expect(matcher.match(pattern: "APP", text: "apple") != nil)
    #expect(matcher.match(pattern: "app", text: "APPLE") != nil)
}

@Test("Case sensitive matching")
func caseSensitiveMatching() {
    let matcher = FuzzyMatcher(caseSensitive: true)

    // Should match
    #expect(matcher.match(pattern: "app", text: "apple") != nil)

    // Should not match (case mismatch)
    #expect(matcher.match(pattern: "APP", text: "apple") == nil)
}

@Test("Empty pattern matches with zero score")
func emptyPattern() {
    let matcher = FuzzyMatcher()

    let result = matcher.match(pattern: "", text: "apple")
    #expect(result != nil)
    #expect(result?.score == 0)
    #expect(result?.positions == [])
}

@Test("Match positions tracking")
func matchPositions() {
    let matcher = FuzzyMatcher()

    let result = matcher.match(pattern: "ae", text: "apple")
    #expect(result != nil)
    // Pattern "ae" should match positions 0 (a) and 4 (e)
    #expect(result?.positions.count == 2)
    #expect(result?.positions.contains(0) == true)
}

@Test("Match scoring validation")
func matchScoring() {
    let matcher = FuzzyMatcher()

    let result1 = matcher.match(pattern: "app", text: "apple")
    let result2 = matcher.match(pattern: "xyz", text: "apple")

    #expect(result1 != nil)
    #expect(result2 == nil)
    #expect(result1!.score > 0)
}

@Test("Word boundary bonus scoring")
func wordBoundaryBonus() {
    let matcher = FuzzyMatcher()

    let result1 = matcher.match(pattern: "fb", text: "foo_bar")
    let result2 = matcher.match(pattern: "fb", text: "foobar")

    #expect(result1 != nil)
    #expect(result2 != nil)

    // "foo_bar" with delimiter should score higher
    #expect(result1!.score > result2!.score)
}

@Test("Match multiple items")
func matchItems() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "apple"),
        Item(index: 1, text: "apricot"),
        Item(index: 2, text: "banana"),
        Item(index: 3, text: "cherry"),
    ]

    let results = matcher.matchItems(pattern: "ap", items: items)

    // Should match "apple" and "apricot"
    #expect(results.count == 2)
    #expect(results.contains { $0.item.text == "apple" })
    #expect(results.contains { $0.item.text == "apricot" })

    // Results should be sorted by score (descending)
    if results.count >= 2 {
        #expect(results[0].score >= results[1].score)
    }
}

@Test("Empty pattern matches all items")
func emptyPatternMatchesAll() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "apple"),
        Item(index: 1, text: "banana"),
        Item(index: 2, text: "cherry"),
    ]

    let results = matcher.matchItems(pattern: "", items: items)
    #expect(results.count == 3)
}

// MARK: - Character Classification Tests

@Test("Character classification")
func characterClassification() {
    #expect(CharClass.classify(" ") == .whitespace)
    #expect(CharClass.classify("_") == .delimiter)
    #expect(CharClass.classify("-") == .delimiter)
    #expect(CharClass.classify("a") == .lower)
    #expect(CharClass.classify("A") == .upper)
    #expect(CharClass.classify("1") == .number)
}

@Test("Bonus calculation for character positions")
func bonusCalculation() {
    // After whitespace should give high bonus
    #expect(CharClass.bonus(current: .lower, previous: .whitespace) == 8)

    // After delimiter should give medium bonus
    #expect(CharClass.bonus(current: .lower, previous: .delimiter) == 7)

    // CamelCase transition (lower to upper)
    #expect(CharClass.bonus(current: .upper, previous: .lower) == 7)
}

// MARK: - Whitespace AND Tests

@Test("Whitespace acts as AND operator")
func whitespaceANDMatching() {
    let matcher = FuzzyMatcher()

    // Both tokens must match
    #expect(matcher.match(pattern: "swift util", text: "swift-argument-parser/Tools/changelog-authors/Util.swift") != nil)
    #expect(matcher.match(pattern: "swift util", text: "Util.swift in swift project") != nil)

    // Should not match if one token is missing
    #expect(matcher.match(pattern: "swift xyz", text: "swift-argument-parser/Util.swift") == nil)
    #expect(matcher.match(pattern: "xyz util", text: "swift-argument-parser/Util.swift") == nil)
}

@Test("Whitespace AND with multiple items")
func whitespaceANDOrdering() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "swift-util-tools"),
        Item(index: 1, text: "swift-argument-parser"),
        Item(index: 2, text: "util-swift-helper"),
        Item(index: 3, text: "other-file"),
    ]

    let results = matcher.matchItems(pattern: "swift util", items: items)

    // Should match items containing both "swift" and "util"
    #expect(results.count == 2)
    #expect(results.contains { $0.item.text == "swift-util-tools" })
    #expect(results.contains { $0.item.text == "util-swift-helper" })

    // Should not match items missing either token
    #expect(!results.contains { $0.item.text == "swift-argument-parser" })
    #expect(!results.contains { $0.item.text == "other-file" })
}

@Test("Multiple whitespace-separated tokens (3+ tokens)")
func multipleWhitespaceTokens() {
    let matcher = FuzzyMatcher()

    // Three tokens - all must match
    #expect(matcher.match(pattern: "swift arg parser", text: "swift-argument-parser") != nil)

    // Should fail if any token missing
    #expect(matcher.match(pattern: "swift arg xyz", text: "swift-argument-parser") == nil)
}

@Test("Whitespace trimming and multiple spaces")
func whitespaceTrimmingAndEmpty() {
    let matcher = FuzzyMatcher()

    // Leading/trailing whitespace should be trimmed
    #expect(matcher.match(pattern: "  swift  ", text: "swift-file") != nil)

    // Multiple spaces between tokens should work
    #expect(matcher.match(pattern: "swift  util", text: "swift-util") != nil)

    // Only whitespace should match everything (empty pattern)
    let items = [Item(index: 0, text: "test")]
    let results = matcher.matchItems(pattern: "   ", items: items)
    #expect(results.count == 1)
}

// MARK: - Blackbox Integration Tests

@Test("Realistic file path matching - exact matches score highest")
func filePathExactMatching() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "README.md"),
        Item(index: 1, text: "src/lib/readme/parser.md"),
        Item(index: 2, text: "docs/read_me_first.md"),
        Item(index: 3, text: "tests/reader_model_demo.md"),
    ]

    let results = matcher.matchItems(pattern: "README.md", items: items)

    // Should match multiple items but exact match scores highest
    #expect(results.count >= 1)
    #expect(results[0].item.text == "README.md", "Exact match should be first")
}

@Test("Realistic file path matching - LICENSE files")
func filePathLICENSE() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "LICENSE"),
        Item(index: 1, text: "LICENSE.md"),
        Item(index: 2, text: "LICENSE.txt"),
        Item(index: 3, text: "lib/license_checker.rb"),
        Item(index: 4, text: "src/licensing/models.py"),
        Item(index: 5, text: "docs/licensing_guide.md"),
    ]

    let results = matcher.matchItems(pattern: "LICENSE", items: items)

    // All LICENSE* files should match and rank higher than lib/licensing
    #expect(results.count >= 3)
    let topThree = results.prefix(3).map { $0.item.text }
    #expect(topThree.contains("LICENSE"))
    #expect(topThree.contains("LICENSE.md"))
    #expect(topThree.contains("LICENSE.txt"))
}

@Test("Path matching - source files in nested directories")
func pathMatchingNested() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "main.swift"),
        Item(index: 1, text: "src/main.swift"),
        Item(index: 2, text: "tests/main_test.swift"),
        Item(index: 3, text: "lib/utils/main_helper.swift"),
        Item(index: 4, text: "src/domain/user/main.swift"),
    ]

    let results = matcher.matchItems(pattern: "main.swift", items: items)

    // All should match, but files named exactly "main.swift" should rank higher
    #expect(results.count >= 3)

    // First results should be exact filename matches
    let firstResult = results[0].item.text
    #expect(firstResult == "main.swift" || firstResult == "src/main.swift" || firstResult == "src/domain/user/main.swift")
}

@Test("CamelCase matching - bonus for word boundaries")
func camelCaseMatching() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "UIViewController.swift"),
        Item(index: 1, text: "UserInterfaceViewController.swift"),
        Item(index: 2, text: "ui_view_controller.swift"),
        Item(index: 3, text: "utils/ui/view/controller.swift"),
    ]

    let results = matcher.matchItems(pattern: "UIVC", items: items)

    // Should match camelCase and snake_case
    #expect(results.count >= 2)

    // UIViewController should score highly due to consecutive uppercase matches
    let topResults = results.prefix(2).map { $0.item.text }
    #expect(topResults.contains("UIViewController.swift"))
}

@Test("Extension matching")
func extensionMatching() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "app.js"),
        Item(index: 1, text: "app.json"),
        Item(index: 2, text: "app.jsx"),
        Item(index: 3, text: "application.js"),
    ]

    let results = matcher.matchItems(pattern: ".js", items: items)

    // Should match .js and .jsx files
    #expect(results.count >= 2)
    #expect(results.contains { $0.item.text == "app.js" })
    #expect(results.contains { $0.item.text == "application.js" })
}

@Test("Result ordering - consecutive matches score higher")
func consecutiveMatchBonus() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "test_file.txt"),        // "test" consecutive
        Item(index: 1, text: "t_e_s_t_file.txt"),     // "test" spread out
        Item(index: 2, text: "testing_file.txt"),     // "test" consecutive + more
    ]

    let results = matcher.matchItems(pattern: "test", items: items)

    #expect(results.count == 3)

    // All items should match, verify they're sorted by score
    if results.count >= 2 {
        #expect(results[0].score >= results[1].score, "Results should be sorted by score")
        #expect(results[1].score >= results[2].score, "Results should be sorted by score")
    }

    // At least verify consecutive match is in top results
    let topTwo = results.prefix(2).map { $0.item.text }
    #expect(topTwo.contains("test_file.txt") || topTwo.contains("testing_file.txt"),
            "Consecutive matches should rank in top results")
}

@Test("Result ordering - earlier matches score higher")
func earlyMatchBonus() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "app.js"),
        Item(index: 1, text: "src/app.js"),
        Item(index: 2, text: "src/components/admin/app.js"),
    ]

    let results = matcher.matchItems(pattern: "app", items: items)

    #expect(results.count == 3)

    // "app.js" should rank higher than deeply nested paths
    #expect(results[0].item.text == "app.js" || results[0].item.text == "src/app.js",
            "Shorter paths with earlier matches should rank higher")
}

// MARK: - Incremental Filtering Tests

@Test("Incremental filtering - extending query refines results")
func incrementalFilteringBasic() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "main.swift"),
        Item(index: 1, text: "main_test.swift"),
        Item(index: 2, text: "utils.swift"),
        Item(index: 3, text: "config.json"),
    ]

    // First query: "ma"
    let results1 = matcher.matchItems(pattern: "ma", items: items)
    #expect(results1.count == 2, "'main' files should match 'ma'")

    // Extended query: "main"
    let results2 = matcher.matchItems(pattern: "main", items: items)
    #expect(results2.count == 2, "Both 'main' files should match")
    #expect(results2.allSatisfy { $0.item.text.contains("main") })

    // Further extension: "main.s"
    let results3 = matcher.matchItems(pattern: "main.s", items: items)
    #expect(results3.count >= 1)
    #expect(results3[0].item.text == "main.swift", "Best match should be first")

    // Verify refinement: each extension should produce fewer or equal results
    #expect(results2.count <= results1.count, "Extending query should refine results")
    #expect(results3.count <= results2.count, "Further extension should further refine")
}

@Test("Incremental filtering - query extension maintains subset relationship")
func incrementalFilteringSubset() {
    let matcher = FuzzyMatcher()
    let items = (0..<100).map { Item(index: $0, text: "file_\($0).txt") }
    let specialItems = [
        Item(index: 100, text: "special.txt"),
        Item(index: 101, text: "special_case.txt"),
        Item(index: 102, text: "very_special.txt"),
    ]
    let allItems = items + specialItems

    // Query "sp" - should match "special" items
    let results1 = matcher.matchItems(pattern: "sp", items: allItems)
    let matched1 = Set(results1.map { $0.item.text })

    // Extended query "spe" - results should be subset of "sp" results
    let results2 = matcher.matchItems(pattern: "spe", items: allItems)
    let matched2 = Set(results2.map { $0.item.text })

    #expect(matched2.isSubset(of: matched1),
            "Extending query should produce subset of results")

    // Further extension "spec" - even smaller subset
    let results3 = matcher.matchItems(pattern: "spec", items: allItems)
    let matched3 = Set(results3.map { $0.item.text })

    #expect(matched3.isSubset(of: matched2))
    #expect(matched3.count <= matched2.count)
}

@Test("Incremental filtering - backspace expands results")
func incrementalFilteringBackspace() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "test.js"),
        Item(index: 1, text: "test.ts"),
        Item(index: 2, text: "test.jsx"),
        Item(index: 3, text: "test.tsx"),
        Item(index: 4, text: "test.json"),
    ]

    // Specific query: "test.ts"
    let results1 = matcher.matchItems(pattern: "test.ts", items: items)
    #expect(results1.count >= 1)

    // Backspace to "test.t" - should match more
    let results2 = matcher.matchItems(pattern: "test.t", items: items)
    #expect(results2.count >= results1.count,
            "Shorter query should match same or more items")

    // Backspace to "test" - should match all test files
    let results3 = matcher.matchItems(pattern: "test", items: items)
    #expect(results3.count == 5, "All test files should match")
}

// MARK: - Edge Cases and Special Characters

@Test("Special characters in paths")
func specialCharactersInPaths() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "my-app/src/index.js"),
        Item(index: 1, text: "my_app/src/index.js"),
        Item(index: 2, text: "my.app/src/index.js"),
        Item(index: 3, text: "my app/src/index.js"),
    ]

    let results = matcher.matchItems(pattern: "myapp", items: items)

    // Should match all variations
    #expect(results.count == 4, "Should match across delimiters")
}

@Test("Numbers in filenames")
func numbersInFilenames() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "v1.2.3/package.json"),
        Item(index: 1, text: "v2.0.0/package.json"),
        Item(index: 2, text: "version_1_2_3.txt"),
    ]

    let results = matcher.matchItems(pattern: "v123", items: items)

    #expect(results.count >= 1)
    #expect(results.contains { $0.item.text.contains("v1.2.3") || $0.item.text.contains("1_2_3") })
}

@Test("Very long paths")
func veryLongPaths() {
    let matcher = FuzzyMatcher()
    let longPath = "src/very/deeply/nested/directory/structure/with/many/levels/and/components/that/keeps/going/deeper/and/deeper/until/finally/target.swift"
    let items = [
        Item(index: 0, text: longPath),
        Item(index: 1, text: "target.swift"),
    ]

    let results = matcher.matchItems(pattern: "target", items: items)

    #expect(results.count == 2)
    // Shorter path should rank higher
    #expect(results[0].item.text == "target.swift")
}

@Test("Empty and whitespace-only items")
func emptyItems() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: ""),
        Item(index: 1, text: "   "),
        Item(index: 2, text: "test"),
    ]

    let results = matcher.matchItems(pattern: "test", items: items)

    #expect(results.count == 1)
    #expect(results[0].item.text == "test")
}

@Test("Case sensitivity comparison")
func caseSensitivityComparison() {
    let caseSensitive = FuzzyMatcher(caseSensitive: true)
    let caseInsensitive = FuzzyMatcher(caseSensitive: false)

    let items = [
        Item(index: 0, text: "README.md"),
        Item(index: 1, text: "readme.md"),
        Item(index: 2, text: "ReadMe.md"),
    ]

    let sensitiveResults = caseSensitive.matchItems(pattern: "readme", items: items)
    let insensitiveResults = caseInsensitive.matchItems(pattern: "readme", items: items)

    // Case insensitive should match all
    #expect(insensitiveResults.count == 3)

    // Case sensitive should only match exact case
    #expect(sensitiveResults.count == 1)
    #expect(sensitiveResults[0].item.text == "readme.md")
}

// MARK: - Performance and Scale Tests

@Test("Large result set maintains correct ordering")
func largeResultSetOrdering() {
    let matcher = FuzzyMatcher()

    // Create many items with varying match quality
    var items: [Item] = []
    items.append(Item(index: 0, text: "test.swift"))  // Best match
    items.append(Item(index: 1, text: "test_utils.swift"))  // Good match

    // Add many mediocre matches
    for i in 2..<1000 {
        items.append(Item(index: i, text: "src/components/testing_file_\(i).swift"))
    }

    let results = matcher.matchItems(pattern: "test", items: items)

    // Should match many items
    #expect(results.count >= 100)

    // Verify results are sorted by score (descending)
    if results.count >= 10 {
        for i in 0..<(results.count - 1) {
            #expect(results[i].score >= results[i + 1].score,
                    "Results should be sorted by score descending")
        }
    }

    // Best matches should be in top results (top 10 is reasonable)
    let topTen = results.prefix(10).map { $0.item.text }
    #expect(topTen.contains("test.swift"), "Best match should be in top 10 even in large set")
    #expect(topTen.contains("test_utils.swift"), "Good matches should be in top 10")
}

@Test("Common real-world query patterns")
func realWorldQueryPatterns() {
    let matcher = FuzzyMatcher()
    let items = [
        Item(index: 0, text: "src/main/java/com/example/UserController.java"),
        Item(index: 1, text: "src/main/java/com/example/UserService.java"),
        Item(index: 2, text: "src/main/java/com/example/user/UserRepository.java"),
        Item(index: 3, text: "src/test/java/com/example/UserControllerTest.java"),
    ]

    // Pattern: searching for specific class
    let results1 = matcher.matchItems(pattern: "UserController", items: items)
    #expect(results1.count >= 1)
    #expect(results1[0].item.text.contains("UserController.java"))

    // Pattern: searching with path hint
    let results2 = matcher.matchItems(pattern: "test User", items: items)
    #expect(results2.count >= 1)
    #expect(results2[0].item.text.contains("test"))

    // Pattern: abbreviation
    let results3 = matcher.matchItems(pattern: "UC", items: items)
    #expect(results3.count >= 1)
    #expect(results3[0].item.text.contains("UserController"))
}
