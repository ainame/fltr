import Foundation
import TUI
import AsyncAlgorithms

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
    private let useFloatingPreview: Bool  // true = floating window, false = split-screen
    private var cachedPreview: String = ""  // Cache to avoid re-running preview on every render
    private var showFloatingPreview: Bool = false  // Toggle floating preview window (float mode)
    private var showSplitPreview: Bool  // Toggle split preview (split mode, starts enabled)
    private var previewScrollOffset: Int = 0  // Scroll offset for preview content
    private let multiSelect: Bool  // Whether Tab selection is enabled

    // Preview window bounds for mouse hit testing (1-indexed, inclusive)
    private var previewBounds: (startRow: Int, endRow: Int, startCol: Int, endCol: Int)?

    // Debounce support with AsyncSequence
    private let debounceDelay: Duration  // Delay before executing match after typing
    private let queryUpdateStream: AsyncStream<[Item]>
    private let queryUpdateContinuation: AsyncStream<[Item]>.Continuation

    init(terminal: RawTerminal, matcher: FuzzyMatcher, cache: ItemCache, reader: StdinReader, maxHeight: Int? = nil, multiSelect: Bool = false, previewCommand: String? = nil, useFloatingPreview: Bool = false, debounceDelay: Duration = .milliseconds(100)) {
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

        // Create AsyncStream for query changes
        var continuation: AsyncStream<[Item]>.Continuation!
        let stream = AsyncStream<[Item]> { continuation = $0 }
        self.queryUpdateStream = stream
        self.queryUpdateContinuation = continuation
    }

    /// Run the main UI loop
    func run() async throws -> [Item] {
        try await terminal.enterRawMode()

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

        // Start debounced query update task
        let debounceTask = Task {
            for await allItems in queryUpdateStream.debounce(for: debounceDelay) {
                await updateMatchesIncremental(allItems: allItems)
                await updatePreview()
                await render()
            }
        }

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

                        // Re-run current query with new items (bypasses debounce)
                        await updateMatchesIncremental(allItems: allItems)
                        await render()

                        lastRefresh = now
                    }
                }

                // Sleep briefly to avoid busy-waiting
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        // Clean up debounce task
        queryUpdateContinuation.finish()
        debounceTask.cancel()

        // Exit raw mode synchronously before returning to ensure terminal is restored
        // before any output is written to stdout
        await terminal.exitRawMode()

        return state.getSelectedItems()
    }

    private func handleKey(byte: UInt8, allItems: [Item]) async {
        // Calculate visible height for scrolling
        let (rows, _) = (try? await terminal.getSize()) ?? (24, 80)
        let availableRows = rows - 4  // Account for input, border, status, and spacing
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
            scheduleMatchUpdate(allItems: allItems)

        case .backspace:
            state.deleteChar()
            scheduleMatchUpdate(allItems: allItems)

        case .enter:
            state.shouldExit = true
            state.exitWithSelection = true

        case .escape, .ctrlC:
            state.shouldExit = true
            state.exitWithSelection = false

        case .ctrlU:
            state.clearQuery()
            scheduleMatchUpdate(allItems: allItems)

        case .ctrlK:
            state.deleteToEndOfLine()
            scheduleMatchUpdate(allItems: allItems)

        case .ctrlA:
            state.moveCursorToStart()

        case .ctrlE:
            state.moveCursorToEnd()

        case .ctrlF:
            state.moveCursorRight()

        case .ctrlB:
            state.moveCursorLeft()

        case .left:
            state.moveCursorLeft()

        case .right:
            state.moveCursorRight()

        case .up:
            state.moveUp(visibleHeight: visibleHeight)
            await updatePreview()

        case .down:
            state.moveDown(visibleHeight: visibleHeight)
            await updatePreview()

        case .tab:
            if multiSelect {
                state.toggleSelection()
            }

        case .ctrlO:
            // Toggle preview window (style depends on useFloatingPreview flag)
            if previewCommand != nil {
                if useFloatingPreview {
                    showFloatingPreview.toggle()
                    if showFloatingPreview {
                        await updatePreview()
                    }
                } else {
                    showSplitPreview.toggle()
                    if showSplitPreview {
                        await updatePreview()
                    }
                }
            }

        case .mouseScrollUp(let col, let row):
            if isMouseOverPreview(col: col, row: row) {
                // Scroll preview up (decrease offset)
                previewScrollOffset = max(0, previewScrollOffset - 3)
            } else {
                // Scroll list up
                state.moveUp(visibleHeight: visibleHeight)
                await updatePreview()
            }

        case .mouseScrollDown(let col, let row):
            if isMouseOverPreview(col: col, row: row) {
                // Scroll preview down (increase offset)
                let lines = cachedPreview.split(separator: "\n", omittingEmptySubsequences: false)
                let maxOffset = max(0, lines.count - 1)
                previewScrollOffset = min(maxOffset, previewScrollOffset + 3)
            } else {
                // Scroll list down
                state.moveDown(visibleHeight: visibleHeight)
                await updatePreview()
            }

        default:
            break
        }
    }

    /// Emit query change event to debounced stream
    private func scheduleMatchUpdate(allItems: [Item]) {
        queryUpdateContinuation.yield(allItems)
    }

    /// Check if mouse position is over preview window
    private func isMouseOverPreview(col: Int, row: Int) -> Bool {
        guard let bounds = previewBounds else { return false }
        return row >= bounds.startRow && row <= bounds.endRow &&
               col >= bounds.startCol && col <= bounds.endCol
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
        let listWidth: Int
        let previewWidth: Int
        let previewStartCol: Int

        if showSplitPreview {
            // Split-screen: 50/50 layout with vertical separator
            listWidth = cols / 2 - 1
            previewWidth = cols - listWidth - 1
            previewStartCol = listWidth + 2
        } else {
            // Full width for list
            listWidth = cols
            previewWidth = 0
            previewStartCol = 0
        }

        // Build entire frame in a single buffer to minimize actor calls
        var buffer = ""

        // Clear screen
        buffer += "\u{001B}[2J"  // Clear entire screen

        // Render input line (positions itself)
        buffer += renderInputLineToBuffer(cols: listWidth)

        // Render border line below input
        buffer += renderBorderLineToBuffer(cols: listWidth)

        // Render matched items (positions each line)
        buffer += renderItemListToBuffer(displayHeight: displayHeight, cols: listWidth)

        // Render status bar (positions itself)
        buffer += renderStatusBarToBuffer(row: displayHeight + 3, cols: listWidth)

        // Render split preview if enabled
        if showSplitPreview {
            let startRow = 3
            let endRow = displayHeight + 2
            // Store bounds for mouse hit testing (inclusive)
            previewBounds = (startRow: startRow, endRow: endRow, startCol: previewStartCol, endCol: cols)
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

    private func renderInputLineToBuffer(cols: Int) -> String {
        let prompt = "> "
        let availableWidth = cols - prompt.count - 1

        // Build query with cursor
        let query = state.query
        let cursorPos = state.cursorPosition

        // ANSI codes for cursor (inverted colors)
        let cursorStart = "\u{001B}[7m"  // Reverse video
        let cursorEnd = "\u{001B}[27m"   // Normal video

        var displayText = ""

        if query.isEmpty {
            // Show cursor at empty position
            displayText = cursorStart + " " + cursorEnd
        } else {
            // Insert cursor into query string
            let queryChars = Array(query)
            for (index, char) in queryChars.enumerated() {
                if index == cursorPos {
                    displayText += cursorStart + String(char) + cursorEnd
                } else {
                    displayText += String(char)
                }
            }

            // If cursor is at the end, show space cursor
            if cursorPos >= queryChars.count {
                displayText += cursorStart + " " + cursorEnd
            }
        }

        // Truncate if too long (preserving ANSI codes is handled by visual width)
        let displayQuery = TextRenderer.truncate(displayText, width: availableWidth)

        return "\u{001B}[1;1H" + prompt + displayQuery + "\u{001B}[K"
    }

    private func renderBorderLineToBuffer(cols: Int) -> String {
        let dimColor = "\u{001B}[2m"  // Dim/faint text
        let resetColor = "\u{001B}[0m"
        let border = String(repeating: "─", count: cols - 1)
        return "\u{001B}[2;1H" + dimColor + border + resetColor + "\u{001B}[K"
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
            let row = displayIndex + 3  // Start from row 3 (after input on row 1 and border on row 2)
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
        let displayHeight = maxHeight ?? row - 3  // Approximate from row parameter (status is at displayHeight + 3)

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
            previewScrollOffset = 0
            return
        }

        let selectedItem = state.matchedItems[state.selectedIndex]
        let newPreview = await executePreviewCommand(command, item: selectedItem.item.text)

        // Reset scroll offset when preview content changes (new item selected)
        if newPreview != cachedPreview {
            previewScrollOffset = 0
        }

        cachedPreview = newPreview
    }

    /// Execute preview command with item text substitution
    private func executePreviewCommand(_ command: String, item: String) async -> String {
        // Replace {} with item text, shell-escape it
        let escapedItem = item.replacingOccurrences(of: "'", with: "'\\''")
        let expandedCommand = command.replacingOccurrences(of: "{}", with: "'\(escapedItem)'")

        // Execute via shell with timeout
        return await withTaskGroup(of: String.self) { group in
            group.addTask {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", expandedCommand]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()

                    // Read data in background
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    // Limit output size to avoid memory issues
                    let maxBytes = 1_000_000  // 1MB
                    let limitedData = data.prefix(maxBytes)

                    if let output = String(data: limitedData, encoding: .utf8) {
                        // Limit lines too
                        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                        if lines.count > 1000 {
                            return lines.prefix(1000).joined(separator: "\n") + "\n\n[Output truncated - showing first 1000 lines]"
                        }
                        return output
                    }
                } catch {
                    return "Error: \(error.localizedDescription)"
                }

                return ""
            }

            // Timeout task
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return "[Preview timeout - command took too long]"
            }

            // Return first result (either success or timeout)
            if let result = await group.next() {
                group.cancelAll()
                return result
            }

            return "[Preview failed]"
        }
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

    /// Render split-screen preview (fzf style)
    private func renderSplitPreview(startRow: Int, endRow: Int, startCol: Int, width: Int) -> String {
        guard previewCommand != nil else { return "" }

        var buffer = ""
        let lines = cachedPreview.split(separator: "\n", omittingEmptySubsequences: false)
        let maxLines = endRow - startRow + 1

        // Swift orange for separator
        let separatorColor = "\u{001B}[1;38;5;202m"
        let resetColor = "\u{001B}[0m"

        // Draw vertical separator
        for row in startRow...endRow {
            buffer += "\u{001B}[\(row);\(startCol - 1)H"
            buffer += separatorColor + "│" + resetColor
        }

        // Draw preview content with scroll offset
        for i in 0..<maxLines {
            let row = startRow + i
            let lineIndex = previewScrollOffset + i

            buffer += "\u{001B}[\(row);\(startCol)H\u{001B}[K"

            if lineIndex < lines.count {
                let line = String(lines[lineIndex])
                // Replace tabs with spaces
                let lineWithoutTabs = line.replacingOccurrences(of: "\t", with: "    ")
                let truncated = TextRenderer.truncate(lineWithoutTabs, width: width)
                buffer += truncated
            }
        }

        return buffer
    }

    /// Render floating window with borders for preview
    /// Returns bounds tuple and buffer string
    private func renderFloatingPreview(rows: Int, cols: Int) -> ((startRow: Int, endRow: Int, startCol: Int, endCol: Int)?, String) {
        guard showFloatingPreview, previewCommand != nil else { return (nil, "") }

        // Calculate window dimensions (80% of screen, centered)
        let windowWidth = Int(Double(cols) * 0.8)
        let windowHeight = Int(Double(rows) * 0.7)
        let startRow = (rows - windowHeight) / 2
        let startCol = (cols - windowWidth) / 2
        let endRow = startRow + windowHeight - 1
        let endCol = startCol + windowWidth - 1
        let bounds = (startRow: startRow, endRow: endRow, startCol: startCol, endCol: endCol)

        // Swift orange for borders
        let borderColor = "\u{001B}[1;38;5;202m"
        let resetColor = "\u{001B}[0m"

        var buffer = ""
        let lines = cachedPreview.split(separator: "\n", omittingEmptySubsequences: false)

        // Get selected item name for title (left-aligned with margin)
        let itemName = !state.matchedItems.isEmpty
            ? state.matchedItems[state.selectedIndex].item.text
            : ""
        // Replace tabs and truncate title to avoid width issues
        let sanitizedName = itemName.replacingOccurrences(of: "\t", with: " ")
        let maxTitleLength = windowWidth - 16  // Leave room for padding and borders
        let truncatedName = TextRenderer.truncate(sanitizedName, width: maxTitleLength)
        let title = " Preview: \(truncatedName) "

        // Clear and draw each line of the window
        for i in 0..<windowHeight {
            let row = startRow + i

            // Position cursor and clear entire line first
            buffer += "\u{001B}[\(row);\(startCol)H\u{001B}[K"

            if i == 0 {
                // Top border with title (left-aligned with 2-char left margin)
                let titleLeftMargin = 2
                let leftBorder = String(repeating: "─", count: titleLeftMargin)
                let rightBorder = String(repeating: "─", count: max(0, windowWidth - title.count - titleLeftMargin - 2))
                buffer += borderColor + "┌" + leftBorder + resetColor + title + borderColor + rightBorder + "┐" + resetColor

            } else if i == windowHeight - 1 {
                // Bottom border with help text (centered)
                let helpText = " Ctrl-O to close "
                let helpLeftMargin = (windowWidth - helpText.count - 2) / 2
                let bottomLeft = String(repeating: "─", count: max(0, helpLeftMargin))
                let bottomRight = String(repeating: "─", count: max(0, windowWidth - helpLeftMargin - helpText.count - 2))
                buffer += borderColor + "└" + bottomLeft + resetColor + helpText + borderColor + bottomRight + "┘" + resetColor

            } else {
                // Content line with left/right borders (single line)
                let contentWidth = windowWidth - 2
                let contentIndex = i - 1
                let lineIndex = previewScrollOffset + contentIndex

                buffer += borderColor + "│" + resetColor

                if lineIndex < lines.count {
                    let line = String(lines[lineIndex])
                    // Replace tabs with spaces to avoid width calculation issues
                    let lineWithoutTabs = line.replacingOccurrences(of: "\t", with: "    ")
                    let truncated = TextRenderer.truncate(lineWithoutTabs, width: contentWidth)
                    // Use padWithoutANSI which handles ANSI codes + emoji/CJK display width
                    buffer += TextRenderer.padWithoutANSI(truncated, width: contentWidth)
                } else {
                    buffer += String(repeating: " ", count: contentWidth)
                }

                buffer += borderColor + "│" + resetColor
            }
        }

        return (bounds, buffer)
    }
}
