import Foundation
import TUI
import AsyncAlgorithms

/// Single-field message yielded into the debounced query stream.
/// previousQuery is intentionally absent — it is read fresh from the actor
/// at the point of consumption to avoid staleness.
struct QueryUpdate: Sendable {
    let query: String
}

/// Main UI controller - event loop and rendering
actor UIController {
    private let terminal: any Terminal
    private let matcher: FuzzyMatcher
    private let engine: MatchingEngine
    private let cache: ItemCache
    private let textBuffer: TextBuffer  // captured once; ItemCache.buffer is a let
    private let reader: StdinReader
    private var state = UIState()
    private var maxHeight: Int?  // nil = use full terminal height
    private var lastItemCount: Int = 0
    private var isReadingStdin: Bool = true  // Cache to avoid async call in render
    private let previewCommand: String?
    private let useFloatingPreview: Bool  // true = floating window, false = split-screen
    private var cachedPreview: String = ""  // Cache to avoid re-running preview on every render
    private var showFloatingPreview: Bool = false  // Toggle floating preview window (float mode)
    private var showSplitPreview: Bool  // Toggle split preview (split mode, starts enabled)
    private var previewScrollOffset: Int = 0  // Scroll offset for preview content
    private let multiSelect: Bool  // Whether Tab selection is enabled

    private var previewBounds: PreviewBounds?  // mouse hit-testing (1-indexed, inclusive)
    private let previewManager: PreviewManager?
    private let renderer: UIRenderer
    private let inputHandler: InputHandler

    // Debounced query stream feeds runMatch; the continuation is the write end.
    private let debounceDelay: Duration
    private let queryUpdateStream: AsyncStream<QueryUpdate>
    private let queryUpdateContinuation: AsyncStream<QueryUpdate>.Continuation

    // Cancellable background tasks
    private var currentMatchTask: Task<Void, Never>?
    private var currentPreviewTask: Task<Void, Never>?
    private var fetchItemsTask: Task<Void, Never>?

    private var renderScheduled = false  // coalesces concurrent render requests

    // Merger-level result cache (mirrors fzf's mergerCache).
    // Keyed on (pattern, itemCount).  Invalidated whenever allItems changes.
    // Only stores results when count <= mergerCacheMax to avoid holding huge
    // arrays in memory for low-selectivity queries.
    private var mergerCachePattern: String = ""
    private var mergerCacheResults: ResultMerger = .empty
    private var mergerCacheItemCount: Int = 0
    private static let mergerCacheMax = 100_000

    // Per-chunk result cache (mirrors fzf's ChunkCache).
    // Shared across TaskGroup partitions; internally locked.
    private let chunkCache = ChunkCache()

    // Set to true the moment the exit decision is made.  Guards render() and
    // applyMatchResults() so that in-flight detached tasks cannot spill ANSI
    // escape sequences onto stdout after ttyFd has been closed.
    private var isExiting = false

    init(terminal: any Terminal, matcher: FuzzyMatcher, cache: ItemCache, reader: StdinReader, maxHeight: Int? = nil, multiSelect: Bool = false, previewCommand: String? = nil, useFloatingPreview: Bool = false, debounceDelay: Duration = .milliseconds(50)) {
        self.terminal = terminal
        self.matcher = matcher
        self.engine = MatchingEngine(matcher: matcher)
        self.cache = cache
        self.textBuffer = cache.buffer
        self.reader = reader
        self.maxHeight = maxHeight
        self.multiSelect = multiSelect
        self.previewCommand = previewCommand
        self.useFloatingPreview = useFloatingPreview
        self.showSplitPreview = previewCommand != nil && !useFloatingPreview
        self.debounceDelay = debounceDelay

        self.previewManager = previewCommand != nil
            ? PreviewManager(command: previewCommand, useFloatingPreview: useFloatingPreview)
            : nil
        self.renderer = UIRenderer(maxHeight: maxHeight, multiSelect: multiSelect)
        self.inputHandler = InputHandler(
            multiSelect: multiSelect,
            hasPreview: previewCommand != nil,
            useFloatingPreview: useFloatingPreview
        )

        var continuation: AsyncStream<QueryUpdate>.Continuation!
        let stream = AsyncStream<QueryUpdate> { continuation = $0 }
        self.queryUpdateStream = stream
        self.queryUpdateContinuation = continuation
    }

    /// Run the main UI loop
    func run() async throws -> [Item] {
        try await terminal.enterRawMode()

        // Initial snapshot — may be empty if stdin is still streaming.
        let initialChunkList = await cache.snapshotChunkList()
        lastItemCount = initialChunkList.count
        state.totalItems = initialChunkList.count
        let initialMatches = await engine.matchChunksParallel(pattern: "", chunkList: initialChunkList, cache: chunkCache, buffer: textBuffer)
        state.updateMatches(initialMatches)

        refreshPreview()
        await render()

        var lastRefresh = Date()
        let refreshInterval: TimeInterval = 0.1  // Refresh every 100ms when new items arrive

        // Debounced matching runs OUTSIDE the actor so it never blocks input.
        // Each iteration waits for the previous match to finish (so that
        // state.merger is up-to-date for incremental filtering), then fires
        // a new detached task that does the heavy work.
        let debounceTask = Task {
            for await update in queryUpdateStream.debounce(for: debounceDelay) {
                if let prevTask = currentMatchTask {
                    _ = await prevTask.value
                }

                // Snapshot actor state while we still have isolation.
                let previousQuery  = self.state.previousQuery
                let currentMerger  = self.state.merger
                let chunkList      = await self.cache.snapshotChunkList()
                self.updatePreviousQuery(update.query)

                currentMatchTask = Task.detached {
                    await self.runMatch(
                        query: update.query,
                        previousQuery: previousQuery,
                        merger: currentMerger,
                        chunkList: chunkList
                    )
                }
            }
        }

        // Main event loop
        while !state.shouldExit {
            // Exit if the controlling terminal has disconnected (e.g. shell closed the
            // subshell, or the terminal emulator was closed).  Without this check fltr
            // would loop forever burning CPU and memory.
            if await terminal.ttyBroken {
                break
            }

            isReadingStdin = await !reader.readingComplete()

            if let byte = await terminal.readByte() {
                await handleKey(byte: byte)
                scheduleRender()
            } else {
                let currentCount = await cache.count()

                if currentCount > lastItemCount {
                    let now = Date()
                    if now.timeIntervalSince(lastRefresh) >= refreshInterval {
                        lastItemCount = currentCount
                        state.totalItems = currentCount

                        fetchItemsTask?.cancel()
                        currentMatchTask?.cancel()

                        // Re-match against the fresh item set in the background.
                        // Always a full search: previousQuery is owned by the
                        // debounce task; writing it here would let the debounce
                        // path see a stale value and permanently cap its results.
                        fetchItemsTask = Task.detached {
                            let chunkList = await self.cache.snapshotChunkList()
                            let query     = await self.state.query

                            await self.invalidateMergerCache()
                            self.chunkCache.clear()

                            await self.runMatch(
                                query: query,
                                previousQuery: "",  // force full search
                                merger: .empty,
                                chunkList: chunkList
                            )
                        }

                        lastRefresh = now
                    }
                }

                // Brief sleep to reduce CPU usage when no input available
                // Terminal readByte already has 100ms timeout, so combined we check
                // for updates approximately every 110ms when idle
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        // Freeze state and suppress any in-flight renders before we tear down
        // the terminal.  Without this, a detached match task that races past
        // its cancellation checkpoint can call render() while UIController is
        // suspended on exitRawMode(), enqueue a write on RawTerminal after
        // ttyFd is closed, and spill the entire UI frame onto stdout.
        isExiting = true

        queryUpdateContinuation.finish()
        currentMatchTask?.cancel()
        currentPreviewTask?.cancel()
        fetchItemsTask?.cancel()
        debounceTask.cancel()

        await terminal.exitRawMode()

        return state.getSelectedItems()
    }

    private func handleKey(byte: UInt8) async {
        let (rows, _) = (try? await terminal.getSize()) ?? (24, 80)
        let availableRows = rows - 4  // input + border + status + spacing
        let visibleHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        let key = await inputHandler.parseEscapeSequence(firstByte: byte, terminal: terminal)

        let context = InputContext(
            visibleHeight: visibleHeight,
            cachedPreview: cachedPreview,
            previewScrollOffset: previewScrollOffset,
            previewBounds: previewBounds
        )

        // Handle key event
        let action = inputHandler.handleKeyEvent(key: key, state: &state, context: context)

        switch action {
        case .none:
            break

        case .scheduleMatchUpdate:
            scheduleMatchUpdate()

        case .updatePreview:
            refreshPreview()

        case .updatePreviewScroll(let offset):
            previewScrollOffset = offset

        case .togglePreview:
            if useFloatingPreview {
                showFloatingPreview.toggle()
                if showFloatingPreview { refreshPreview() }
            } else {
                showSplitPreview.toggle()
                if showSplitPreview { refreshPreview() }
            }
        }
    }

    private func scheduleMatchUpdate() {
        let update = QueryUpdate(query: state.query)
        queryUpdateContinuation.yield(update)
    }

    /// Cancel any in-flight preview and kick off a fresh one in the background.
    /// Every call site that needs a new preview reduces to this single path.
    private func refreshPreview() {
        guard let manager = previewManager, let command = previewCommand else { return }
        currentPreviewTask?.cancel()
        currentPreviewTask = Task.detached {
            await self.updatePreviewAsync(manager: manager, command: command)
            await self.render()
        }
    }

    private func updatePreviousQuery(_ query: String) {
        state.previousQuery = query
    }

    private func applyMatchResults(_ results: ResultMerger) {
        guard !isExiting else { return }
        state.updateMatches(results)
    }

    private func updatePreviewAsync(manager: PreviewManager, command: String) async {
        guard let selectedItem = state.merger.get(state.selectedIndex) else {
            cachedPreview = ""
            previewScrollOffset = 0
            return
        }

        let newPreview = await manager.executeCommand(command, item: selectedItem.item.text(in: textBuffer))
        setCachedPreview(newPreview)
    }

    private func setCachedPreview(_ preview: String) {
        if preview != cachedPreview {
            previewScrollOffset = 0
        }
        cachedPreview = preview
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true

        Task {
            await render()
            renderScheduled = false
        }
    }

    // MARK: - Matching

    /// Core match loop: determine whether to use the incremental or full-search
    /// path, consult / populate the merger cache, then apply results and render.
    /// Called from detached tasks; everything that touches actor state goes
    /// through `await self.*` helper calls.
    nonisolated private func runMatch(
        query: String,
        previousQuery: String,
        merger: ResultMerger,
        chunkList: ChunkList
    ) async {
        let overallStart = Date()

        // Incremental filtering: when the new query extends the previous one
        // the previous match set is a strict superset, so narrowing is lossless.
        let canUseIncremental = !previousQuery.isEmpty &&
                                query.hasPrefix(previousQuery) &&
                                query.count > previousQuery.count

        // Merger cache hit — only valid on the full-search path (the
        // incremental candidate set is a subset and would differ).
        if !canUseIncremental, let cached = await lookupMergerCache(pattern: query, itemCount: chunkList.count) {
            await applyMatchResults(cached)
            await refreshPreviewIfNeeded(results: cached)
            await render()
            return
        }

        let matchStart = Date()
        let results: ResultMerger
        if canUseIncremental {
            results = await engine.matchItemsParallel(pattern: query, items: merger.allItems(), buffer: textBuffer)
        } else {
            results = await engine.matchChunksParallel(pattern: query, chunkList: chunkList, cache: chunkCache, buffer: textBuffer)
        }

        logMatchTime(
            query: query,
            matchTime: Date().timeIntervalSince(matchStart) * 1000,
            totalTime: Date().timeIntervalSince(overallStart) * 1000,
            itemCount: chunkList.count,
            resultCount: results.count
        )

        if !canUseIncremental {
            await storeMergerCache(pattern: query, itemCount: chunkList.count, results: results)
        }

        await applyMatchResults(results)
        await refreshPreviewIfNeeded(results: results)
        await render()
    }

    /// Update the cached preview when there are results to show.
    nonisolated private func refreshPreviewIfNeeded(results: ResultMerger) async {
        guard results.count > 0, let manager = previewManager, let command = previewCommand else { return }
        await updatePreviewAsync(manager: manager, command: command)
    }

    /// Append a single perf-log line when a match round takes > 10 ms.
    private nonisolated func logMatchTime(query: String, matchTime: Double, totalTime: Double, itemCount: Int, resultCount: Int) {
        guard matchTime > 10 else { return }
        let msg = "[\(query)] match: \(String(format: "%.1f", matchTime))ms (\(itemCount) items → \(resultCount) results), total: \(String(format: "%.1f", totalTime))ms\n"
        let path = URL(fileURLWithPath: "/tmp/fltr-perf.log")
        if let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile()
            handle.write(msg.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? msg.data(using: .utf8)?.write(to: path)
        }
    }

    // MARK: - Merger cache helpers (actor-isolated, O(1))

    /// Return cached results if pattern and item-count match the last stored entry.
    private func lookupMergerCache(pattern: String, itemCount: Int) -> ResultMerger? {
        guard pattern == mergerCachePattern && itemCount == mergerCacheItemCount else { return nil }
        return mergerCacheResults
    }

    /// Store results in the merger cache.  Gated by mergerCacheMax so that
    /// low-selectivity queries (e.g. single character on 800 k items) do not
    /// occupy memory with little reuse benefit.
    private func storeMergerCache(pattern: String, itemCount: Int, results: ResultMerger) {
        guard results.count <= Self.mergerCacheMax else { return }
        mergerCachePattern = pattern
        mergerCacheResults = results
        mergerCacheItemCount = itemCount
    }

    private func invalidateMergerCache() {
        mergerCachePattern = ""
        mergerCacheResults = .empty
        mergerCacheItemCount = 0
    }

    private func render() async {
        guard !isExiting else { return }
        let rawSize = (try? await terminal.getSize()) ?? (24, 80)
        let rows = max(5, rawSize.0)
        let cols = max(10, rawSize.1)

        // Layout: input | border | items… | status  →  4 rows of chrome
        let availableRows = rows - 4
        let displayHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        let previewWidth: Int
        let previewStartCol: Int
        if showSplitPreview {
            let listWidth = cols / 2 - 1
            previewWidth = cols - listWidth - 1
            previewStartCol = listWidth + 2
        } else {
            previewWidth = 0
            previewStartCol = 0
        }

        let context = RenderContext(
            rows: rows,
            cols: cols,
            isReadingStdin: isReadingStdin,
            showSplitPreview: showSplitPreview,
            showFloatingPreview: showFloatingPreview
        )

        // Materialise the visible window here; assembleFrame receives state
        // by value and cannot call mutating Merger methods itself.
        let visibleItems = state.merger.slice(state.scrollOffset, state.scrollOffset + displayHeight)
        var buffer = renderer.assembleFrame(state: state, visibleItems: visibleItems, context: context, buffer: textBuffer)

        if showSplitPreview {
            let startRow = 3
            let endRow = displayHeight + 2
            previewBounds = PreviewBounds(startRow: startRow, endRow: endRow, startCol: previewStartCol, endCol: cols)
            buffer += renderSplitPreview(startRow: startRow, endRow: endRow, startCol: previewStartCol, width: previewWidth)
        } else if showFloatingPreview {
            let (floatingBounds, floatingBuffer) = renderFloatingPreview(rows: rows, cols: cols)
            previewBounds = floatingBounds
            buffer += floatingBuffer
        } else {
            previewBounds = nil
        }

        await terminal.write(buffer)
        await terminal.flush()
    }

    private func renderSplitPreview(startRow: Int, endRow: Int, startCol: Int, width: Int) -> String {
        guard let manager = previewManager else { return "" }
        return manager.renderSplitPreview(
            content: cachedPreview,
            scrollOffset: previewScrollOffset,
            startRow: startRow,
            endRow: endRow,
            startCol: startCol,
            width: width
        )
    }

    private func renderFloatingPreview(rows: Int, cols: Int) -> (PreviewBounds?, String) {
        guard showFloatingPreview, let manager = previewManager else { return (nil, "") }

        let itemName = state.merger.get(state.selectedIndex).map { $0.item.text(in: textBuffer) } ?? ""

        return manager.renderFloatingPreview(
            content: cachedPreview,
            scrollOffset: previewScrollOffset,
            itemName: itemName,
            rows: rows,
            cols: cols
        )
    }
}
