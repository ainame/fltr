import Foundation
import FltrLib

/// Simple benchmark comparing Character-based vs UTF-8 byte-based matching
public struct MatcherBenchmark {
    /// Benchmark dataset
    static let testData = [
        "src/components/Header.tsx",
        "src/components/Footer.tsx",
        "src/utils/string-helpers.ts",
        "src/pages/index.tsx",
        "src/pages/about.tsx",
        "tests/unit/components/Header.test.tsx",
        "tests/integration/api/users.test.ts",
        "README.md",
        "package.json",
        "tsconfig.json",
        "node_modules/react/index.js",
        "node_modules/@types/react/index.d.ts",
    ]

    static let queries = [
        "src",
        "test",
        "Header",
        "tsx",
        "components",
        "react",
    ]

    /// Run benchmark and return timing in milliseconds
    static func benchmark(
        name: String,
        iterations: Int = 10_000,
        matcher: (String, String) -> MatchResult?
    ) -> Double {
        let start = Date()

        for _ in 0..<iterations {
            for query in queries {
                for text in testData {
                    _ = matcher(query, text)
                }
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        let totalMatches = iterations * queries.count * testData.count
        let matchesPerSecond = Double(totalMatches) / elapsed

        print("[\(name)]")
        print("  Total time: \(String(format: "%.3f", elapsed * 1000))ms")
        print("  Matches: \(totalMatches)")
        print("  Matches/sec: \(String(format: "%.0f", matchesPerSecond))")
        print("  Time per match: \(String(format: "%.3f", (elapsed * 1_000_000) / Double(totalMatches)))μs")

        return elapsed * 1000
    }

    public static func runComparison() {
        print("=== Matcher Performance Comparison ===\n")

        let timeCharacter = benchmark(name: "Character-based (FuzzyMatchV2)") { pattern, text in
            FuzzyMatchV2.match(pattern: pattern, text: text, caseSensitive: false)
        }

        print()

        let timeUtf8 = benchmark(name: "UTF-8 byte-based (Utf8FuzzyMatch)") { pattern, text in
            Utf8FuzzyMatch.match(pattern: pattern, text: text, caseSensitive: false)
        }

        print()
        print("=== Summary ===")
        print("Speedup: \(String(format: "%.2f", timeCharacter / timeUtf8))x")
    }
}
