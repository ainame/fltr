import Foundation
import ArgumentParser
import TUI

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

    mutating func run() async throws {
        // Initialize components
        let cache = ItemCache()
        let reader = StdinReader(cache: cache)

        // Start reading stdin in background (non-blocking!)
        let readTask = await reader.startReading()

        // Wait briefly for initial items to load
        try? await Task.sleep(for: .milliseconds(100))

        // Determine preview style
        let previewCommand = preview ?? previewFloat
        let useFloatingPreview = previewFloat != nil

        // Initialize UI components
        let terminal = RawTerminal()
        let matcher = FuzzyMatcher(caseSensitive: caseSensitive)
        let ui = UIController(
            terminal: terminal,
            matcher: matcher,
            cache: cache,
            reader: reader,
            maxHeight: height,
            previewCommand: previewCommand,
            useFloatingPreview: useFloatingPreview
        )

        // Run UI (starts immediately, even if stdin still reading)
        let selectedItems = try await ui.run()

        // Cancel background reading if still active
        readTask.cancel()

        // Output results
        for item in selectedItems {
            print(item.text)
        }
    }
}

