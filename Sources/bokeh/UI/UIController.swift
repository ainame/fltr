import Foundation

/// Main UI controller - event loop and rendering
actor UIController {
    private let terminal: RawTerminal
    private let matcher: FuzzyMatcher
    private let cache: ItemCache
    private var state = UIState()
    private var maxHeight: Int?  // nil = use full terminal height

    init(terminal: RawTerminal, matcher: FuzzyMatcher, cache: ItemCache, maxHeight: Int? = nil) {
        self.terminal = terminal
        self.matcher = matcher
        self.cache = cache
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

        // Initial load
        let items = await cache.getAllItems()
        state.totalItems = items.count
        state.updateMatches(matcher.matchItems(pattern: "", items: items))

        await render()

        // Main event loop
        while !state.shouldExit {
            if let byte = await terminal.readByte() {
                await handleKey(byte: byte, allItems: items)
                await render()
            } else {
                // No input, sleep briefly
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        return state.getSelectedItems()
    }

    private func handleKey(byte: UInt8, allItems: [Item]) async {
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
            state.updateMatches(matcher.matchItems(pattern: state.query, items: allItems))

        case .backspace:
            state.deleteChar()
            state.updateMatches(matcher.matchItems(pattern: state.query, items: allItems))

        case .enter:
            state.shouldExit = true
            state.exitWithSelection = true

        case .escape, .ctrlC:
            state.shouldExit = true
            state.exitWithSelection = false

        case .ctrlU:
            state.clearQuery()
            state.updateMatches(matcher.matchItems(pattern: state.query, items: allItems))

        case .up:
            state.moveUp()

        case .down:
            state.moveDown()

        case .tab:
            state.toggleSelection()

        default:
            break
        }
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
        let displayItems = Array(state.matchedItems.prefix(displayHeight))

        for (index, matchedItem) in displayItems.enumerated() {
            let row = index + 2
            await terminal.moveCursor(row: row, col: 1)
            await terminal.clearLine()

            let isSelected = state.selectedIndex == index
            let isMarked = state.selectedItems.contains(matchedItem.item.index)

            var prefix = "  "
            if isMarked {
                prefix = " >"
            }
            if isSelected {
                prefix = String(prefix.dropFirst()) + ">"
            }

            let text = matchedItem.item.text
            let availableWidth = cols - prefix.count - 1
            // Use the new ANSI-safe truncate and highlight
            let displayText = TextRenderer.truncateAndHighlight(
                text,
                positions: matchedItem.matchResult.positions,
                width: availableWidth
            )

            let line = prefix + displayText
            await terminal.write(line)
        }
    }

    private func renderStatusBar(row: Int, cols: Int) async {
        await terminal.moveCursor(row: row, col: 1)
        await terminal.clearLine()

        let status: String
        if state.selectedItems.isEmpty {
            status = "\(state.matchedItems.count)/\(state.totalItems)"
        } else {
            status = "\(state.matchedItems.count)/\(state.totalItems) (\(state.selectedItems.count) selected)"
        }

        await terminal.write(TextRenderer.pad(status, width: cols))
    }
}
