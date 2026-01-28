import Testing
@testable import fltr

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
