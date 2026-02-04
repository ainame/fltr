import TUI

public struct Options {
    public let height: Int?
    public let multi: Bool
    public let caseSensitive: Bool
    public let preview: String?
    public let previewFloat: String?
    public let scheme: SortScheme

    public init(height: Int?, multi: Bool, caseSensitive: Bool, preview: String?, previewFloat: String?, scheme: SortScheme = .path) {
        self.height = height
        self.multi = multi
        self.caseSensitive = caseSensitive
        self.preview = preview
        self.previewFloat = previewFloat
        self.scheme = scheme
    }
}

public struct Runner {
    public let options: Options

    public init(options: Options) {
        self.options = options
    }

    /// Non-interactive query mode: read all stdin, run the same matchChunksParallel
    /// path the interactive UI uses, and dump top results with rank points to stdout.
    public func runQuery(_ query: String) async throws {
        let cache = ItemCache()
        let reader = StdinReader(cache: cache)
        let readTask = await reader.startReading()

        // Wait for stdin to finish — no timeout, we need the full dataset
        await readTask.value

        let matcher = FuzzyMatcher(caseSensitive: options.caseSensitive, scheme: options.scheme)
        let engine = MatchingEngine(matcher: matcher)
        let chunkList = await cache.snapshotChunkList()
        let chunkCache = ChunkCache()

        var merger = await engine.matchChunksParallel(pattern: query, chunkList: chunkList, cache: chunkCache)

        let totalItems = await cache.count()
        print("[query='\(query)' scheme=\(options.scheme) results=\(merger.count)/\(totalItems)]")
        print("")
        for (i, m) in merger.slice(0, 30).enumerated() {
            print("  #\(i + 1)  score=\(m.score)  pts=(\(m.points.3),\(m.points.2),\(m.points.1),\(m.points.0))  pos=\(m.matchResult.positions)  \(m.item.text)")
        }
    }

    public func run() async throws {
        // Initialize components
        let cache = ItemCache()
        let reader = StdinReader(cache: cache)

        // Start reading stdin in background (non-blocking!)
        let readTask = await reader.startReading()

        // Wait briefly for initial items to load
        try? await Task.sleep(for: .milliseconds(100))

        // Determine preview style
        let previewCommand = options.preview ?? options.previewFloat
        let useFloatingPreview = options.previewFloat != nil

        // Initialize UI components
        let terminal = RawTerminal()
        let matcher = FuzzyMatcher(caseSensitive: options.caseSensitive, scheme: options.scheme)
        let ui = UIController(
            terminal: terminal,
            matcher: matcher,
            cache: cache,
            reader: reader,
            maxHeight: options.height,
            multiSelect: options.multi,
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
