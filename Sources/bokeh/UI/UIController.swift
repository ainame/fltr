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
    private var isReadingStdin: Bool = true  // Cache to avoid async call in render
    private let previewCommand: String?
    private var cachedPreview: String = ""  // Cache to avoid re-running preview on every render
    private var showFloatingPreview: Bool = false  // Toggle floating preview window

    init(terminal: RawTerminal, matcher: FuzzyMatcher, cache: ItemCache, reader: StdinReader, maxHeight: Int? = nil, previewCommand: String? = nil) {
        self.terminal = terminal
        self.matcher = matcher
        self.engine = MatchingEngine(matcher: matcher)
        self.cache = cache
        self.reader = reader
        self.maxHeight = maxHeight
        self.previewCommand = previewCommand
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

        await updatePreview()
        await render()

        var lastRefresh = Date()
        let refreshInterval: TimeInterval = 0.1  // Refresh every 100ms when new items arrive

        // Main event loop
        while !state.shouldExit {
            // Update reading status cache
            isReadingStdin = await !reader.readingComplete()

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
            await updatePreview()

        case .backspace:
            state.deleteChar()
            await updateMatchesIncremental(allItems: allItems)
            await updatePreview()

        case .enter:
            state.shouldExit = true
            state.exitWithSelection = true

        case .escape, .ctrlC:
            state.shouldExit = true
            state.exitWithSelection = false

        case .ctrlU:
            state.clearQuery()
            await updateMatchesIncremental(allItems: allItems)
            await updatePreview()

        case .up:
            state.moveUp(visibleHeight: visibleHeight)
            await updatePreview()

        case .down:
            state.moveDown(visibleHeight: visibleHeight)
            await updatePreview()

        case .tab:
            state.toggleSelection()

        case .ctrlO:
            // Toggle floating preview window
            if previewCommand != nil {
                showFloatingPreview.toggle()
                if showFloatingPreview {
                    await updatePreview()
                }
            }

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

        // Use full width if floating preview or no preview
        let listWidth = cols

        // Build entire frame in a single buffer to minimize actor calls
        var buffer = ""

        // Clear screen
        buffer += "\u{001B}[2J"  // Clear entire screen

        // Render input line (positions itself)
        buffer += renderInputLineToBuffer(cols: listWidth)

        // Render matched items (positions each line)
        buffer += renderItemListToBuffer(displayHeight: displayHeight, cols: listWidth)

        // Render status bar (positions itself)
        buffer += renderStatusBarToBuffer(row: displayHeight + 2, cols: listWidth)

        // Render floating preview window if enabled
        if showFloatingPreview {
            buffer += renderFloatingPreview(rows: rows, cols: cols)
        }

        // Single write for entire frame
        await terminal.write(buffer)
        await terminal.flush()
    }

    private func renderInputLineToBuffer(cols: Int) -> String {
        let prompt = "> "
        let displayQuery = TextRenderer.truncate(state.query, width: cols - prompt.count - 1)
        return "\u{001B}[1;1H" + prompt + displayQuery + "\u{001B}[K"
    }

    private func renderItemListToBuffer(displayHeight: Int, cols: Int) -> String {
        // Pre-define ANSI codes to avoid repeated string allocations
        let swiftOrange = "\u{001B}[1;38;5;202m"
        let resetFg = "\u{001B}[22;39m"
        let bgColor = "\u{001B}[48;5;236m"
        let resetAll = "\u{001B}[0m"

        // Get visible slice of matched items based on scrollOffset
        let startIndex = state.scrollOffset
        let endIndex = min(startIndex + displayHeight, state.matchedItems.count)
        let visibleItems = Array(state.matchedItems[startIndex..<endIndex])

        var buffer = ""
        for (displayIndex, matchedItem) in visibleItems.enumerated() {
            let row = displayIndex + 2
            let actualIndex = startIndex + displayIndex

            let isSelected = state.selectedIndex == actualIndex
            let isMarked = state.selectedItems.contains(matchedItem.item.index)

            var prefix = "  "
            if isMarked {
                prefix = " \(swiftOrange)>\(resetFg)"
            }
            if isSelected {
                if isMarked {
                    prefix = "\(swiftOrange)>>\(resetFg)"
                } else {
                    prefix = " \(swiftOrange)>\(resetFg)"
                }
            }

            // Apply background color for selected line
            let bgStart = isSelected ? bgColor : ""
            let bgEnd = isSelected ? resetAll : ""

            let text = matchedItem.item.text
            let prefixVisualWidth = 2
            let availableWidth = cols - prefixVisualWidth - 1

            // Truncate and highlight
            let displayText = TextRenderer.truncateAndHighlight(
                text,
                positions: matchedItem.matchResult.positions,
                width: availableWidth
            )

            // Pad line to full width
            let content = prefix + displayText
            let paddedLine = TextRenderer.padWithoutANSI(content, width: cols - 1)

            // Position cursor and write line
            buffer += "\u{001B}[\(row);1H\u{001B}[K"
            buffer += bgStart + paddedLine + bgEnd
        }

        return buffer
    }

    private func renderStatusBarToBuffer(row: Int, cols: Int) -> String {
        var status: String
        if state.selectedItems.isEmpty {
            status = "\(state.matchedItems.count)/\(state.totalItems)"
        } else {
            status = "\(state.matchedItems.count)/\(state.totalItems) (\(state.selectedItems.count) selected)"
        }

        // Show loading indicator if still reading stdin (cached value, no async)
        if isReadingStdin {
            status += " [loading...]"
        }

        // Add scroll indicator if there are more items than visible
        let displayHeight = maxHeight ?? row - 2  // Approximate from row parameter

        if state.matchedItems.count > displayHeight {
            let scrollPercent = Int((Double(state.scrollOffset) / Double(max(1, state.matchedItems.count - displayHeight))) * 100)
            status += " [\(scrollPercent)%]"
        }

        return "\u{001B}[\(row);1H\u{001B}[K" + TextRenderer.pad(status, width: cols)
    }

    /// Update preview for currently selected item
    private func updatePreview() async {
        guard let command = previewCommand else { return }
        guard !state.matchedItems.isEmpty else {
            cachedPreview = ""
            return
        }

        let selectedItem = state.matchedItems[state.selectedIndex]
        cachedPreview = await executePreviewCommand(command, item: selectedItem.item.text)
    }

    /// Execute preview command with item text substitution
    private func executePreviewCommand(_ command: String, item: String) async -> String {
        // Replace {} with item text
        let expandedCommand = command.replacingOccurrences(of: "{}", with: item)

        // Execute via shell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", expandedCommand]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output
            }
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        return ""
    }

    /// Render preview pane to buffer
    private func renderPreviewToBuffer(startRow: Int, endRow: Int, startCol: Int, width: Int) -> String {
        guard previewCommand != nil else { return "" }

        var buffer = ""
        let lines = cachedPreview.split(separator: "\n", omittingEmptySubsequences: false)
        let maxLines = endRow - startRow + 1

        for (index, line) in lines.prefix(maxLines).enumerated() {
            let row = startRow + index
            let truncated = TextRenderer.truncate(String(line), width: width)
            buffer += "\u{001B}[\(row);\(startCol)H\u{001B}[K"
            buffer += truncated
        }

        // Clear remaining lines if preview is shorter
        for row in (startRow + lines.count)..<endRow {
            buffer += "\u{001B}[\(row);\(startCol)H\u{001B}[K"
        }

        return buffer
    }

    /// Render floating window with borders for preview
    private func renderFloatingPreview(rows: Int, cols: Int) -> String {
        guard showFloatingPreview, previewCommand != nil else { return "" }

        // Calculate window dimensions (80% of screen, centered)
        let windowWidth = Int(Double(cols) * 0.8)
        let windowHeight = Int(Double(rows) * 0.7)
        let startRow = (rows - windowHeight) / 2
        let startCol = (cols - windowWidth) / 2

        var buffer = ""
        let lines = cachedPreview.split(separator: "\n", omittingEmptySubsequences: false)

        // Get selected item name for title
        let itemName = !state.matchedItems.isEmpty
            ? state.matchedItems[state.selectedIndex].item.text
            : ""
        let title = " Preview: \(itemName) "

        // Draw top border with title
        buffer += "\u{001B}[\(startRow);\(startCol)H"
        buffer += "╔"
        let titleStart = (windowWidth - title.count - 2) / 2
        let leftBorder = String(repeating: "═", count: max(0, titleStart))
        let rightBorder = String(repeating: "═", count: max(0, windowWidth - titleStart - title.count - 2))
        buffer += leftBorder + title + rightBorder
        buffer += "╗"

        // Draw content with left/right borders
        let contentWidth = windowWidth - 2
        let contentHeight = windowHeight - 2
        for i in 0..<contentHeight {
            let row = startRow + i + 1
            buffer += "\u{001B}[\(row);\(startCol)H║"

            if i < lines.count {
                let line = String(lines[i])
                let truncated = TextRenderer.truncate(line, width: contentWidth)
                buffer += truncated.padding(toLength: contentWidth, withPad: " ", startingAt: 0)
            } else {
                buffer += String(repeating: " ", count: contentWidth)
            }

            buffer += "║"
        }

        // Draw bottom border with help text
        buffer += "\u{001B}[\(startRow + windowHeight - 1);\(startCol)H"
        buffer += "╚"
        let helpText = " Ctrl-O to close "
        let bottomLeft = String(repeating: "═", count: (windowWidth - helpText.count - 2) / 2)
        let bottomRight = String(repeating: "═", count: windowWidth - bottomLeft.count - helpText.count - 2)
        buffer += bottomLeft + helpText + bottomRight
        buffer += "╝"

        // Draw shadow effect (dim gray characters to the right and bottom)
        let shadowColor = "\u{001B}[2;37m"  // Dim white
        let resetColor = "\u{001B}[0m"

        // Right shadow
        for shadowRow in (startRow + 1)...(startRow + windowHeight) {
            buffer += "\u{001B}[\(shadowRow);\(startCol + windowWidth)H"
            buffer += "\(shadowColor)▓\(resetColor)"
        }

        // Bottom shadow
        buffer += "\u{001B}[\(startRow + windowHeight);\(startCol + 1)H"
        buffer += "\(shadowColor)" + String(repeating: "▓", count: windowWidth) + "\(resetColor)"

        return buffer
    }
}
