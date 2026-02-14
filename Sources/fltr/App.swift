import ArgumentParser
import Foundation
import FltrLib

@main
struct App: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fltr",
        abstract: "A fuzzy finder for the terminal",
        discussion: """
        fltr (short for "filter") is a cross-platform fuzzy finder CLI tool.
        Read items from stdin and interactively filter them with fuzzy matching.
        """
    )

    @Option(name: .shortAndLong, help: "Maximum display height (number of result lines). Omit to use full terminal height.")
    var height: Int?

    @Flag(name: .shortAndLong, help: "Enable multi-select mode")
    var multi: Bool = false

    @Flag(name: .long, help: "Enable case-sensitive matching")
    var caseSensitive: Bool = false

    @Option(name: .long, help: "Preview command (split-screen style, like fzf). Use {} as placeholder.")
    var preview: String?

    @Option(name: .long, help: "Preview command (floating window style). Use {} as placeholder.")
    var previewFloat: String?

    @Option(name: .long, help: "Ranking scheme: default (score, length), path (score, pathname, length), history (score only). Mirrors fzf --scheme.")
    var scheme: String = "path"

    @Option(name: .long, help: "Matcher backend: utf8, swfast, or fuzzymatch (upstream FuzzyMatch).")
    var matcher: String = "utf8"

    @Option(name: .long, help: "Non-interactive query mode: read stdin, search for QUERY, print top results with rank points. Useful for scripting and debugging.")
    var query: String?

    mutating func run() async throws {
        guard let sortScheme = SortScheme.parse(scheme) else {
            throw ValidationError("invalid --scheme '\(scheme)' (expected: default, path, history)")
        }
        guard let matcherAlgorithm = MatcherAlgorithm.parse(matcher) else {
            throw ValidationError("invalid --matcher '\(matcher)' (expected: utf8, swfast, fuzzymatch)")
        }
        let runner = Runner(
            options: Options(
                height: height,
                multi: multi,
                caseSensitive: caseSensitive,
                preview: preview,
                previewFloat: previewFloat,
                scheme: sortScheme,
                matcherAlgorithm: matcherAlgorithm
            )
        )
        if let query = query {
            try await runner.runQuery(query)
        } else {
            try await runner.run()
        }
    }
}
