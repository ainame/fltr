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

    mutating func run() async throws {
        let runner = Runner(
            options: Options(
                height: height,
                multi: multi,
                caseSensitive: caseSensitive,
                preview: preview,
                previewFloat: previewFloat,
            )
        )
        try await runner.run()
    }
}

