import Foundation

/// Main UI controller - event loop and rendering
actor UIController {
    private let terminal: RawTerminal
    private let matcher: FuzzyMatcher
    private let engine: MatchingEngine
    private let cache: ItemCache
    private let reader: StdinReader
    private var state = UIState()
    private var maxHeight: Int?  // nil = use full terminal height
    private var lastItemCount: Int = 0

    init(terminal: RawTerminal, matcher: FuzzyMatcher, cache: ItemCache, reader: StdinReader, maxHeight: Int? = nil) {
        self.terminal = terminal
        self.matcher = matcher
        self.engine = MatchingEngine(matcher: matcher)
        self.cache = cache
        self.reader = reader
        self.maxHeight = maxHeight
    }

    /// Run the main UI loop
    func run() async throws -> [Item] {
        try await terminal.enterRawMode()
        defer {
            Task {
                await terminal.exitRawMode()
            }
        }

        // Initial load (might be empty if stdin is slow)
        var allItems = await cache.getAllItems()
        lastItemCount = allItems.count
        state.totalItems = allItems.count
        let initialMatches = await engine.matchItemsParallel(pattern: "", items: allItems)
        state.updateMatches(initialMatches)

        await render()

        var lastRefresh = Date()
        let refreshInterval: TimeInterval = 0.1  // Refresh every 100ms when new items arrive

        // Main event loop
        while !state.shouldExit {
            if let byte = await terminal.readByte() {
                await handleKey(byte: byte, allItems: allItems)
                await render()
            } else {
                // No keyboard input - check if new items arrived
                let currentCount = await cache.count()

                if currentCount > lastItemCount {
                    // New items arrived! Update if enough time passed
                    let now = Date()
                    if now.timeIntervalSince(lastRefresh) >= refreshInterval {
                        allItems = await cache.getAllItems()
                        lastItemCount = currentCount
                        state.totalItems = currentCount

                        // Re-run current query with new items
                        await updateMatchesIncremental(allItems: allItems)
                        await render()

                        lastRefresh = now
                    }
                }

                // Sleep briefly to avoid busy-waiting
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        return state.getSelectedItems()
    }

    private func handleKey(byte: UInt8, allItems: [Item]) async {
        // Calculate visible height for scrolling
        let (rows, _) = (try? await terminal.getSize()) ?? (24, 80)
        let availableRows = rows - 3
        let visibleHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        // Helper to read next byte
        let readNext: () -> UInt8? = {
            // Cannot call async in sync closure, so we'll handle escape sequences differently
            nil
        }
        let key = KeyboardInput.parseKey(firstByte: byte, readNext: readNext)

        // If it was ESC, check for escape sequence manually
        let finalKey: Key
        if case .escape = key, byte == 27 {
            // Check for arrow keys and other escape sequences
            if let next = await terminal.readByte(), next == 91 {
                if let cmd = await terminal.readByte() {
                    switch cmd {
                    case 65: finalKey = .up
                    case 66: finalKey = .down
                    case 67: finalKey = .right
                    case 68: finalKey = .left
                    default: finalKey = .unknown
                    }
                } else {
                    finalKey = .escape
                }
            } else {
                finalKey = .escape
            }
        } else {
            finalKey = key
        }

        switch finalKey {
        case .char(let char):
            state.addChar(char)
            await updateMatchesIncremental(allItems: allItems)

        case .backspace:
            state.deleteChar()
            await updateMatchesIncremental(allItems: allItems)

        case .enter:
            state.shouldExit = true
            state.exitWithSelection = true

        case .escape, .ctrlC:
            state.shouldExit = true
            state.exitWithSelection = false

        case .ctrlU:
            state.clearQuery()
            await updateMatchesIncremental(allItems: allItems)

        case .up:
            state.moveUp(visibleHeight: visibleHeight)

        case .down:
            state.moveDown(visibleHeight: visibleHeight)

        case .tab:
            state.toggleSelection()

        default:
            break
        }
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
        // Layout: row 1 = input, rows 2..N = items, row N+1 = status
        let availableRows = rows - 3  // 1 for input, 1 for status, 1 for spacing
        let displayHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        // Clear screen
        await terminal.moveCursor(row: 1, col: 1)
        await terminal.clearToEnd()

        // Render input line
        await renderInputLine(cols: cols)

        // Render matched items
        await renderItemList(displayHeight: displayHeight, cols: cols)

        // Render status bar
        await renderStatusBar(row: displayHeight + 2, cols: cols)

        await terminal.flush()
    }

    private func renderInputLine(cols: Int) async {
        await terminal.moveCursor(row: 1, col: 1)
        let prompt = "> "
        let displayQuery = TextRenderer.truncate(state.query, width: cols - prompt.count - 1)
        await terminal.write(prompt + displayQuery)
    }

    private func renderItemList(displayHeight: Int, cols: Int) async {
        // Get visible slice of matched items based on scrollOffset
        let startIndex = state.scrollOffset
        let endIndex = min(startIndex + displayHeight, state.matchedItems.count)
        let visibleItems = Array(state.matchedItems[startIndex..<endIndex])

        for (displayIndex, matchedItem) in visibleItems.enumerated() {
            let row = displayIndex + 2
            let actualIndex = startIndex + displayIndex

            await terminal.moveCursor(row: row, col: 1)
            await terminal.clearLine()

            let isSelected = state.selectedIndex == actualIndex
            let isMarked = state.selectedItems.contains(matchedItem.item.index)

            // Swift logo orange color (ANSI 202) with bold, like fzf's cursor
            let swiftOrange = "\u{001B}[1;38;5;202m"
            let resetFg = "\u{001B}[22;39m"  // Reset bold and foreground, keep background

            var prefix = "  "
            if isMarked {
                prefix = " \(swiftOrange)>\(resetFg)"
            }
            if isSelected {
                if isMarked {
                    // Both selected and marked: show cursor after marker
                    prefix = "\(swiftOrange)>>\(resetFg)"
                } else {
                    // Just selected: show cursor
                    prefix = " \(swiftOrange)>\(resetFg)"
                }
            }

            // Apply background color for selected line (like fzf)
            let bgStart = isSelected ? "\u{001B}[48;5;236m" : ""
            let bgEnd = isSelected ? "\u{001B}[0m" : ""

            let text = matchedItem.item.text
            // Calculate visual width of prefix (without ANSI codes, always 2 chars)
            let prefixVisualWidth = 2
            let availableWidth = cols - prefixVisualWidth - 1
            // Use the new ANSI-safe truncate and highlight
            let displayText = TextRenderer.truncateAndHighlight(
                text,
                positions: matchedItem.matchResult.positions,
                width: availableWidth
            )

            // Pad line to full width so background extends across entire line
            let content = prefix + displayText
            let paddedLine = TextRenderer.padWithoutANSI(content, width: cols - 1)
            let line = bgStart + paddedLine + bgEnd
            await terminal.write(line)
        }
    }

    private func renderStatusBar(row: Int, cols: Int) async {
        await terminal.moveCursor(row: row, col: 1)
        await terminal.clearLine()

        var status: String
        if state.selectedItems.isEmpty {
            status = "\(state.matchedItems.count)/\(state.totalItems)"
        } else {
            status = "\(state.matchedItems.count)/\(state.totalItems) (\(state.selectedItems.count) selected)"
        }

        // Show loading indicator if still reading stdin
        let isReading = await !reader.readingComplete()
        if isReading {
            status += " [loading...]"
        }

        // Add scroll indicator if there are more items than visible
        let (rows, _) = (try? await terminal.getSize()) ?? (24, 80)
        let availableRows = rows - 3
        let displayHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        if state.matchedItems.count > displayHeight {
            let scrollPercent = Int((Double(state.scrollOffset) / Double(max(1, state.matchedItems.count - displayHeight))) * 100)
            status += " [\(scrollPercent)%]"
        }

        await terminal.write(TextRenderer.pad(status, width: cols))
    }
}
