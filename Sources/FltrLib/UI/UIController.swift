import Foundation
import TUI
import AsyncAlgorithms

/// Query update message for matching
/// Lightweight - only contains current query
/// Don't capture previousQuery here - read fresh from actor to avoid staleness
struct QueryUpdate: Sendable {
    let query: String
}

/// Main UI controller - event loop and rendering
actor UIController {
    private let terminal: any Terminal
    private let matcher: FuzzyMatcher
    private let engine: MatchingEngine
    private let cache: ItemCache
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

    // Preview window bounds for mouse hit testing (1-indexed, inclusive)
    private var previewBounds: PreviewBounds?

    // Preview manager
    private let previewManager: PreviewManager?

    // UI renderer
    private let renderer: UIRenderer

    // Input handler
    private let inputHandler: InputHandler

    // Debounce support with AsyncSequence
    private let debounceDelay: Duration  // Delay before executing match after typing
    private let queryUpdateStream: AsyncStream<QueryUpdate>
    private let queryUpdateContinuation: AsyncStream<QueryUpdate>.Continuation

    // Current matching task - can be cancelled when new input arrives
    private var currentMatchTask: Task<Void, Never>?

    // Preview update task - can be cancelled when selection changes
    private var currentPreviewTask: Task<Void, Never>?

    // Background task for fetching new items
    private var fetchItemsTask: Task<[Item], Never>?

    // Pending render flag - ensures we don't queue up multiple renders
    private var renderScheduled = false

    // Cached reference to all items (updated when new items arrive)
    private var allItems: [Item] = []

    // Merger-level result cache (mirrors fzf's mergerCache).
    // Keyed on (pattern, itemCount).  Invalidated whenever allItems changes.
    // Only stores results when count <= mergerCacheMax to avoid holding huge
    // arrays in memory for low-selectivity queries.
    private var mergerCachePattern: String = ""
    private var mergerCacheResults: [MatchedItem] = []
    private var mergerCacheItemCount: Int = 0
    private static let mergerCacheMax = 100_000

    // Per-chunk result cache (mirrors fzf's ChunkCache).
    // Shared across TaskGroup partitions; internally locked.
    private let chunkCache = ChunkCache()

    init(terminal: any Terminal, matcher: FuzzyMatcher, cache: ItemCache, reader: StdinReader, maxHeight: Int? = nil, multiSelect: Bool = false, previewCommand: String? = nil, useFloatingPreview: Bool = false, debounceDelay: Duration = .milliseconds(50)) {
        self.terminal = terminal
        self.matcher = matcher
        self.engine = MatchingEngine(matcher: matcher)
        self.cache = cache
        self.reader = reader
        self.maxHeight = maxHeight
        self.multiSelect = multiSelect
        self.previewCommand = previewCommand
        self.useFloatingPreview = useFloatingPreview
        // Split preview starts enabled if we have a preview command and not using floating mode
        self.showSplitPreview = previewCommand != nil && !useFloatingPreview
        self.debounceDelay = debounceDelay

        // Initialize preview manager if preview command is provided
        self.previewManager = previewCommand != nil
            ? PreviewManager(command: previewCommand, useFloatingPreview: useFloatingPreview)
            : nil

        // Initialize UI renderer
        self.renderer = UIRenderer(maxHeight: maxHeight, multiSelect: multiSelect)

        // Initialize input handler
        self.inputHandler = InputHandler(
            multiSelect: multiSelect,
            hasPreview: previewCommand != nil,
            useFloatingPreview: useFloatingPreview
        )

        // Create AsyncStream for query changes
        var continuation: AsyncStream<QueryUpdate>.Continuation!
        let stream = AsyncStream<QueryUpdate> { continuation = $0 }
        self.queryUpdateStream = stream
        self.queryUpdateContinuation = continuation
    }

    /// Run the main UI loop
    func run() async throws -> [Item] {
        try await terminal.enterRawMode()

        // Note: Terminal cleanup is guaranteed by RawTerminal's deinit,
        // but we explicitly call exitRawMode() for proper cleanup
        // Initial load (might be empty if stdin is slow)
        self.allItems = await cache.getAllItems()
        lastItemCount = self.allItems.count
        state.totalItems = self.allItems.count
        let initialMatches = await engine.matchItemsParallel(pattern: "", items: self.allItems)
        state.updateMatches(initialMatches)

        await updatePreview()
        await render()

        var lastRefresh = Date()
        let refreshInterval: TimeInterval = 0.1  // Refresh every 100ms when new items arrive

        // Start debounced query update task
        // This task runs matching OUTSIDE the actor to avoid blocking input
        let debounceTask = Task { [engine, chunkCache, previewCommand, previewManager] in
            for await update in queryUpdateStream.debounce(for: debounceDelay) {
                // Wait for previous task to complete before starting new one
                // This ensures state.matchedItems has the latest results for incremental filtering
                if let prevTask = currentMatchTask {
                    _ = await prevTask.value
                }

                // Now capture state - previous task has updated matchedItems
                let previousQuerySnapshot = self.state.previousQuery
                let currentMatchesSnapshot = self.state.matchedItems
                let allItemsSnapshot = self.allItems
                let chunkListSnapshot = await self.cache.snapshotChunkList()

                // Update previousQuery for next iteration
                self.updatePreviousQuery(update.query)

                // Run matching completely outside the actor (nonisolated)
                currentMatchTask = Task.detached {
                    let overallStart = Date()

                    // Use captured snapshots (avoid async reads that can race)
                    let readStart = Date()
                    let allItems = allItemsSnapshot
                    let currentMatches = currentMatchesSnapshot
                    let readTime = Date().timeIntervalSince(readStart) * 1000

                    // Use previousQuery snapshot from before Task.detached
                    let previousQuery = previousQuerySnapshot

                    // Determine search items based on incremental filtering
                    let canUseIncremental = !previousQuery.isEmpty &&
                                           update.query.hasPrefix(previousQuery) &&
                                           update.query.count > previousQuery.count

                    let searchItems = canUseIncremental ? currentMatches.map { $0.item } : allItems

                    // Merger cache: on the full-search path, check whether we
                    // already have results for this exact (pattern, itemCount).
                    // Skip the cache on the incremental path — the candidate set
                    // is a subset and would produce a different result set.
                    let results: [MatchedItem]
                    if !canUseIncremental, let cached = await self.lookupMergerCache(pattern: update.query, itemCount: allItems.count) {
                        results = cached
                    } else {
                        // Match items (this is the expensive operation)
                        let matchStart = Date()
                        let matchedResults: [MatchedItem]
                        if canUseIncremental {
                            // Incremental path: candidate set is a flat [Item], not chunk-aligned
                            matchedResults = await engine.matchItemsParallel(pattern: update.query, items: searchItems)
                        } else {
                            // Full-search path: use per-chunk cache for keystroke-2+ speed
                            matchedResults = await engine.matchChunksParallel(pattern: update.query, chunkList: chunkListSnapshot, cache: chunkCache)
                        }
                        let matchTime = Date().timeIntervalSince(matchStart) * 1000

                        let totalTime = Date().timeIntervalSince(overallStart) * 1000

                        // Diagnostic output to log file
                        if readTime > 1 || matchTime > 10 {
                            let logMsg = "[\(update.query)] read: \(String(format: "%.1f", readTime))ms, match: \(String(format: "%.1f", matchTime))ms (\(searchItems.count) items → \(matchedResults.count) results), total: \(String(format: "%.1f", totalTime))ms\n"
                            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/fltr-perf.log")) {
                                handle.seekToEndOfFile()
                                handle.write(logMsg.data(using: .utf8)!)
                                try? handle.close()
                            } else {
                                try? logMsg.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/fltr-perf.log"))
                            }
                        }

                        // Store in merger cache only on the full-search path
                        if !canUseIncremental {
                            await self.storeMergerCache(pattern: update.query, itemCount: allItems.count, results: matchedResults)
                        }
                        results = matchedResults
                    }

                    // Update actor state with results (quick actor call)
                    await self.applyMatchResults(results)

                    // Update preview if needed (in background)
                    if previewCommand != nil, let manager = previewManager, !results.isEmpty {
                        await self.updatePreviewAsync(manager: manager, command: previewCommand!)
                    }

                    // Render the updated UI
                    await self.render()
                }

                // Don't wait for completion - let it run in background
                // It will be cancelled if new input arrives
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

            // Update reading status cache
            isReadingStdin = await !reader.readingComplete()

            if let byte = await terminal.readByte() {
                await handleKey(byte: byte)
                scheduleRender()  // Non-blocking render
            } else {
                // No keyboard input - check if new items arrived
                let currentCount = await cache.count()

                if currentCount > lastItemCount {
                    // New items arrived! Update if enough time passed
                    let now = Date()
                    if now.timeIntervalSince(lastRefresh) >= refreshInterval {
                        // Update count without blocking on getAllItems()
                        lastItemCount = currentCount
                        state.totalItems = currentCount

                        // Cancel any previous tasks
                        fetchItemsTask?.cancel()
                        currentMatchTask?.cancel()

                        // Fetch items and re-match in background (doesn't block input!)
                        fetchItemsTask = Task.detached { [cache, engine, chunkCache, previewCommand, previewManager] in
                            // Get all items and chunk-list snapshot outside the actor
                            let newItems = await cache.getAllItems()
                            let chunkListSnapshot = await cache.snapshotChunkList()

                            // Determine search items
                            let query = await self.state.query
                            let previousQuery = await self.state.previousQuery
                            let currentMatches = await self.state.matchedItems

                            let canUseIncremental = !previousQuery.isEmpty &&
                                                   query.hasPrefix(previousQuery) &&
                                                   query.count > previousQuery.count

                            let searchItems = canUseIncremental ? currentMatches.map { $0.item } : newItems

                            // Update previousQuery before matching to prevent race condition
                            await self.updatePreviousQuery(query)

                            // Item count changed → invalidate stale caches before matching
                            await self.invalidateMergerCache()
                            chunkCache.clear()

                            // Match items: full-search uses per-chunk cache; incremental stays flat
                            let results: [MatchedItem]
                            if canUseIncremental {
                                results = await engine.matchItemsParallel(pattern: query, items: searchItems)
                            } else {
                                results = await engine.matchChunksParallel(pattern: query, chunkList: chunkListSnapshot, cache: chunkCache)
                            }

                            // Cache the fresh results on the full-search path
                            if !canUseIncremental {
                                await self.storeMergerCache(pattern: query, itemCount: newItems.count, results: results)
                            }

                            // Update state
                            await self.applyMatchResults(results)

                            // Update preview if needed
                            if previewCommand != nil, let manager = previewManager, !results.isEmpty {
                                await self.updatePreviewAsync(manager: manager, command: previewCommand!)
                            }

                            // Render
                            await self.render()

                            // Return new items to update allItems
                            return newItems
                        }

                        // Update allItems when task completes (if not cancelled)
                        Task {
                            if let newItems = await fetchItemsTask?.value {
                                self.allItems = newItems
                            }
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

        // Clean up tasks
        queryUpdateContinuation.finish()
        currentMatchTask?.cancel()
        currentPreviewTask?.cancel()
        fetchItemsTask?.cancel()
        debounceTask.cancel()

        // Exit raw mode synchronously before returning to ensure terminal is restored
        // before any output is written to stdout
        await terminal.exitRawMode()

        return state.getSelectedItems()
    }

    private func handleKey(byte: UInt8) async {
        // Calculate visible height for scrolling
        let (rows, _) = (try? await terminal.getSize()) ?? (24, 80)
        let availableRows = rows - 4  // Account for input, border, status, and spacing
        let visibleHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        // Parse key using InputHandler
        let key = await inputHandler.parseEscapeSequence(firstByte: byte, terminal: terminal)

        // Create input context
        let context = InputContext(
            visibleHeight: visibleHeight,
            cachedPreview: cachedPreview,
            previewScrollOffset: previewScrollOffset,
            previewBounds: previewBounds
        )

        // Handle key event
        let action = inputHandler.handleKeyEvent(key: key, state: &state, context: context)

        // Execute action
        switch action {
        case .none:
            break

        case .scheduleMatchUpdate:
            scheduleMatchUpdate()

        case .updatePreview:
            // Cancel previous preview task
            currentPreviewTask?.cancel()

            // Update preview in background (don't block input)
            if let manager = previewManager, let command = previewCommand {
                currentPreviewTask = Task.detached {
                    await self.updatePreviewAsync(manager: manager, command: command)
                    await self.render()
                }
            }

        case .updatePreviewScroll(let offset):
            previewScrollOffset = offset

        case .togglePreview:
            if useFloatingPreview {
                showFloatingPreview.toggle()
                if showFloatingPreview {
                    currentPreviewTask?.cancel()
                    if let manager = previewManager, let command = previewCommand {
                        currentPreviewTask = Task.detached {
                            await self.updatePreviewAsync(manager: manager, command: command)
                            await self.render()
                        }
                    }
                }
            } else {
                showSplitPreview.toggle()
                if showSplitPreview {
                    currentPreviewTask?.cancel()
                    if let manager = previewManager, let command = previewCommand {
                        currentPreviewTask = Task.detached {
                            await self.updatePreviewAsync(manager: manager, command: command)
                            await self.render()
                        }
                    }
                }
            }
        }
    }

    /// Emit query change event to debounced stream
    /// Only sends current query - previousQuery read fresh to avoid staleness
    private func scheduleMatchUpdate() {
        let update = QueryUpdate(query: state.query)
        queryUpdateContinuation.yield(update)
    }

    /// Update previousQuery to prevent race conditions in incremental filtering
    private func updatePreviousQuery(_ query: String) {
        state.previousQuery = query
    }

    /// Apply match results to state (actor-isolated, fast)
    /// Note: previousQuery is updated before matching starts to prevent race conditions
    private func applyMatchResults(_ results: [MatchedItem]) {
        state.updateMatches(results)
    }

    /// Update preview asynchronously in background
    private func updatePreviewAsync(manager: PreviewManager, command: String) async {
        guard !state.matchedItems.isEmpty else {
            cachedPreview = ""
            previewScrollOffset = 0
            return
        }

        let selectedItem = state.matchedItems[state.selectedIndex]
        let newPreview = await manager.executeCommand(command, item: selectedItem.item.text)

        // Update cached preview (actor-isolated)
        self.setCachedPreview(newPreview)
    }

    private func setCachedPreview(_ preview: String) {
        if preview != cachedPreview {
            previewScrollOffset = 0
        }
        cachedPreview = preview
    }

    /// Schedule a render without blocking (fire and forget)
    /// Only schedules if no render is already pending to avoid queueing
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true

        Task {
            await render()
            renderScheduled = false
        }
    }

    // MARK: - Merger cache helpers (actor-isolated, O(1))

    /// Return cached results if pattern and item-count match the last stored entry.
    private func lookupMergerCache(pattern: String, itemCount: Int) -> [MatchedItem]? {
        guard pattern == mergerCachePattern && itemCount == mergerCacheItemCount else { return nil }
        return mergerCacheResults
    }

    /// Store results in the merger cache.  Gated by mergerCacheMax so that
    /// low-selectivity queries (e.g. single character on 800 k items) do not
    /// occupy memory with little reuse benefit.
    private func storeMergerCache(pattern: String, itemCount: Int, results: [MatchedItem]) {
        guard results.count <= Self.mergerCacheMax else { return }
        mergerCachePattern = pattern
        mergerCacheResults = results
        mergerCacheItemCount = itemCount
    }

    /// Invalidate the merger cache (called whenever allItems is refreshed).
    private func invalidateMergerCache() {
        mergerCachePattern = ""
        mergerCacheResults = []
        mergerCacheItemCount = 0
    }

    /// Incremental filtering: search within previous results if query is extended
    /// Uses parallel matching engine for large datasets
    private func updateMatchesIncremental(allItems: [Item]) async {
        let newQuery = state.query
        let prevQuery = state.previousQuery

        // Check if new query extends previous query (e.g., "ab" -> "abc")
        let canUseIncremental = !prevQuery.isEmpty &&
                                newQuery.hasPrefix(prevQuery) &&
                                newQuery.count > prevQuery.count

        let searchItems: [Item]
        if canUseIncremental {
            // Search within previous matched items (much faster!)
            searchItems = state.matchedItems.map { $0.item }
        } else {
            // Full search in all items
            searchItems = allItems
        }

        // Use parallel matching engine
        let results = await engine.matchItemsParallel(pattern: newQuery, items: searchItems)
        state.updateMatches(results)
        state.previousQuery = newQuery
    }

    private func render() async {
        let (rows, cols) = (try? await terminal.getSize()) ?? (24, 80)

        // Calculate available rows for items
        // Layout: row 1 = input, row 2 = border, rows 3..N = items, row N+1 = status
        let availableRows = rows - 4  // 1 for input, 1 for border, 1 for status, 1 for spacing
        let displayHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        // Calculate layout based on preview mode
        let previewWidth: Int
        let previewStartCol: Int

        if showSplitPreview {
            // Split-screen: 50/50 layout with vertical separator
            let listWidth = cols / 2 - 1
            previewWidth = cols - listWidth - 1
            previewStartCol = listWidth + 2
        } else {
            // Full width for list
            previewWidth = 0
            previewStartCol = 0
        }

        // Create render context
        let context = RenderContext(
            rows: rows,
            cols: cols,
            isReadingStdin: isReadingStdin,
            showSplitPreview: showSplitPreview,
            showFloatingPreview: showFloatingPreview
        )

        // Build entire frame in a single buffer to minimize actor calls
        var buffer = renderer.assembleFrame(state: state, context: context)

        // Render split preview if enabled
        if showSplitPreview {
            let startRow = 3
            let endRow = displayHeight + 2
            // Store bounds for mouse hit testing (inclusive)
            previewBounds = PreviewBounds(
                startRow: startRow,
                endRow: endRow,
                startCol: previewStartCol,
                endCol: cols
            )
            buffer += renderSplitPreview(
                startRow: startRow,
                endRow: endRow,
                startCol: previewStartCol,
                width: previewWidth
            )
        } else if showFloatingPreview {
            // Render floating preview window if enabled
            let (floatingBounds, floatingBuffer) = renderFloatingPreview(rows: rows, cols: cols)
            previewBounds = floatingBounds
            buffer += floatingBuffer
        } else {
            previewBounds = nil
        }

        // Single write for entire frame
        await terminal.write(buffer)
        await terminal.flush()
    }

    /// Update preview for currently selected item
    private func updatePreview() async {
        guard let manager = previewManager, let command = previewCommand else { return }
        guard !state.matchedItems.isEmpty else {
            cachedPreview = ""
            previewScrollOffset = 0
            return
        }

        let selectedItem = state.matchedItems[state.selectedIndex]
        let newPreview = await manager.executeCommand(command, item: selectedItem.item.text)

        // Reset scroll offset when preview content changes (new item selected)
        if newPreview != cachedPreview {
            previewScrollOffset = 0
        }

        cachedPreview = newPreview
    }

    /// Render split-screen preview using PreviewManager
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

    /// Render floating window using PreviewManager
    private func renderFloatingPreview(rows: Int, cols: Int) -> (PreviewBounds?, String) {
        guard showFloatingPreview, let manager = previewManager else { return (nil, "") }

        let itemName = !state.matchedItems.isEmpty
            ? state.matchedItems[state.selectedIndex].item.text
            : ""

        return manager.renderFloatingPreview(
            content: cachedPreview,
            scrollOffset: previewScrollOffset,
            itemName: itemName,
            rows: rows,
            cols: cols
        )
    }
}
