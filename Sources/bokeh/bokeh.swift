import Foundation
import ArgumentParser

@main
struct Bokeh: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bokeh",
        abstract: "A fuzzy finder for the terminal",
        discussion: """
        bokeh (meaning "fuzzy" in Japanese) is a cross-platform fuzzy finder CLI tool.
        Read items from stdin and interactively filter them with fuzzy matching.
        """
    )

    @Option(name: .shortAndLong, help: "Display height (number of result lines)")
    var height: Int = 10

    @Flag(name: .shortAndLong, help: "Enable multi-select mode")
    var multi: Bool = false

    @Flag(name: .long, help: "Enable case-sensitive matching")
    var caseSensitive: Bool = false

    mutating func run() async throws {
        // Initialize components
        let cache = ItemCache()
        let reader = StdinReader(cache: cache)

        // Read all input
        try await reader.readAll()

        let itemCount = await cache.count()
        guard itemCount > 0 else {
            FileHandle.standardError.write(Data("Error: No items to display\n".utf8))
            throw ExitCode.failure
        }

        // Initialize UI components
        let terminal = RawTerminal()
        let matcher = FuzzyMatcher(caseSensitive: caseSensitive)
        let ui = UIController(terminal: terminal, matcher: matcher, cache: cache, height: height)

        // Run UI
        let selectedItems = try await ui.run()

        // Output results
        for item in selectedItems {
            print(item.text)
        }
    }
}

