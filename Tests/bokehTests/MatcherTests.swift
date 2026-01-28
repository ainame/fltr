import XCTest
@testable import bokeh

final class MatcherTests: XCTestCase {
    func testBasicMatching() {
        let matcher = FuzzyMatcher(caseSensitive: false)

        // Should match
        XCTAssertNotNil(matcher.match(pattern: "ap", text: "apple"))
        XCTAssertNotNil(matcher.match(pattern: "ban", text: "banana"))
        XCTAssertNotNil(matcher.match(pattern: "che", text: "cherry"))

        // Should not match
        XCTAssertNil(matcher.match(pattern: "xyz", text: "apple"))
    }

    func testCaseInsensitiveMatching() {
        let matcher = FuzzyMatcher(caseSensitive: false)

        let result1 = matcher.match(pattern: "APP", text: "apple")
        XCTAssertNotNil(result1)

        let result2 = matcher.match(pattern: "app", text: "APPLE")
        XCTAssertNotNil(result2)
    }

    func testCaseSensitiveMatching() {
        let matcher = FuzzyMatcher(caseSensitive: true)

        // Should match
        XCTAssertNotNil(matcher.match(pattern: "app", text: "apple"))

        // Should not match (case mismatch)
        XCTAssertNil(matcher.match(pattern: "APP", text: "apple"))
    }

    func testEmptyPattern() {
        let matcher = FuzzyMatcher()

        let result = matcher.match(pattern: "", text: "apple")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.score, 0)
        XCTAssertEqual(result?.positions, [])
    }

    func testMatchPositions() {
        let matcher = FuzzyMatcher()

        let result = matcher.match(pattern: "ae", text: "apple")
        XCTAssertNotNil(result)
        // Pattern "ae" should match positions 0 (a) and 4 (e)
        XCTAssertEqual(result?.positions.count, 2)
        XCTAssertTrue(result?.positions.contains(0) ?? false)
    }

    func testMatchScoring() {
        let matcher = FuzzyMatcher()

        // Test that matches occur
        let result1 = matcher.match(pattern: "app", text: "apple")
        let result2 = matcher.match(pattern: "xyz", text: "apple")

        XCTAssertNotNil(result1)
        XCTAssertNil(result2)

        // Verify scoring is positive for valid matches
        XCTAssertGreaterThan(result1!.score, 0)
    }

    func testWordBoundaryBonus() {
        let matcher = FuzzyMatcher()

        // Should prefer word boundaries
        let result1 = matcher.match(pattern: "fb", text: "foo_bar")
        let result2 = matcher.match(pattern: "fb", text: "foobar")

        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)

        // "foo_bar" with delimiter should score higher
        XCTAssertGreaterThan(result1!.score, result2!.score)
    }

    func testMatchItems() {
        let matcher = FuzzyMatcher()
        let items = [
            Item(index: 0, text: "apple"),
            Item(index: 1, text: "apricot"),
            Item(index: 2, text: "banana"),
            Item(index: 3, text: "cherry"),
        ]

        let results = matcher.matchItems(pattern: "ap", items: items)

        // Should match "apple" and "apricot"
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.item.text == "apple" })
        XCTAssertTrue(results.contains { $0.item.text == "apricot" })

        // Results should be sorted by score (descending)
        if results.count >= 2 {
            XCTAssertGreaterThanOrEqual(results[0].score, results[1].score)
        }
    }

    func testEmptyPatternMatchesAll() {
        let matcher = FuzzyMatcher()
        let items = [
            Item(index: 0, text: "apple"),
            Item(index: 1, text: "banana"),
            Item(index: 2, text: "cherry"),
        ]

        let results = matcher.matchItems(pattern: "", items: items)

        // Empty pattern should match all items
        XCTAssertEqual(results.count, 3)
    }

    func testCharacterClassification() {
        XCTAssertEqual(CharClass.classify(" "), .whitespace)
        XCTAssertEqual(CharClass.classify("_"), .delimiter)
        XCTAssertEqual(CharClass.classify("-"), .delimiter)
        XCTAssertEqual(CharClass.classify("a"), .lower)
        XCTAssertEqual(CharClass.classify("A"), .upper)
        XCTAssertEqual(CharClass.classify("1"), .number)
    }

    func testBonusCalculation() {
        // After whitespace should give high bonus
        let bonus1 = CharClass.bonus(current: .lower, previous: .whitespace)
        XCTAssertEqual(bonus1, 8)

        // After delimiter should give medium bonus
        let bonus2 = CharClass.bonus(current: .lower, previous: .delimiter)
        XCTAssertEqual(bonus2, 7)

        // CamelCase transition (lower to upper)
        let bonus3 = CharClass.bonus(current: .upper, previous: .lower)
        XCTAssertEqual(bonus3, 7)
    }
}
