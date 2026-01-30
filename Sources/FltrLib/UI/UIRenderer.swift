import Foundation
import TUI

/// Handles all UI rendering operations
struct UIRenderer: Sendable {
    let maxHeight: Int?
    let multiSelect: Bool

    /// Assemble complete frame buffer for rendering
    func assembleFrame(state: UIState, context: RenderContext) -> String {
        let (rows, cols) = (context.rows, context.cols)

        // Calculate available rows for items
        // Layout: row 1 = input, row 2 = border, rows 3..N = items, row N+1 = status
        let availableRows = rows - 4  // 1 for input, 1 for border, 1 for status, 1 for spacing
        let displayHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        // Calculate layout based on preview mode
        let listWidth: Int

        if context.showSplitPreview {
            // Split-screen: 50/50 layout with vertical separator
            listWidth = cols / 2 - 1
        } else {
            // Full width for list
            listWidth = cols
        }

        // Build entire frame in a single buffer to minimize actor calls
        var buffer = ""

        // Clear screen
        buffer += "\u{001B}[2J"  // Clear entire screen

        // Render input line (positions itself) - use full width
        buffer += renderInputLine(query: state.query, cursorPosition: state.cursorPosition, cols: cols)

        // Render border line below input - use full width
        buffer += renderBorderLine(cols: cols)

        // Render matched items (positions each line)
        buffer += renderItemList(
            matchedItems: state.matchedItems,
            selectedIndex: state.selectedIndex,
            selectedItems: state.selectedItems,
            scrollOffset: state.scrollOffset,
            displayHeight: displayHeight,
            cols: listWidth
        )

        // Calculate actual number of items rendered
        let actualItemsRendered = min(max(0, state.matchedItems.count - state.scrollOffset), displayHeight)

        // Render status bar (positions itself)
        buffer += renderStatusBar(
            matchedCount: state.matchedItems.count,
            totalItems: state.totalItems,
            selectedItems: state.selectedItems,
            isReadingStdin: context.isReadingStdin,
            scrollOffset: state.scrollOffset,
            displayHeight: displayHeight,
            row: actualItemsRendered + 3,
            cols: listWidth
        )

        return buffer
    }

    /// Render input line with cursor
    private func renderInputLine(query: String, cursorPosition: Int, cols: Int) -> String {
        let prompt = "> "
        let availableWidth = cols - prompt.count - 1

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
                if index == cursorPosition {
                    displayText += cursorStart + String(char) + cursorEnd
                } else {
                    displayText += String(char)
                }
            }

            // If cursor is at the end, show space cursor
            if cursorPosition >= queryChars.count {
                displayText += cursorStart + " " + cursorEnd
            }
        }

        // Truncate if too long (preserving ANSI codes is handled by visual width)
        let displayQuery = TextRenderer.truncate(displayText, width: availableWidth)

        return "\u{001B}[1;1H" + prompt + displayQuery + "\u{001B}[K"
    }

    /// Render horizontal border line
    private func renderBorderLine(cols: Int) -> String {
        let dimColor = "\u{001B}[2m"  // Dim/faint text
        let resetColor = "\u{001B}[0m"
        let border = String(repeating: "─", count: cols - 1)
        return "\u{001B}[2;1H" + dimColor + border + resetColor + "\u{001B}[K"
    }

    /// Render item list with highlighting
    private func renderItemList(
        matchedItems: [MatchedItem],
        selectedIndex: Int,
        selectedItems: Set<Int>,
        scrollOffset: Int,
        displayHeight: Int,
        cols: Int
    ) -> String {
        // Pre-define ANSI codes to avoid repeated string allocations
        let swiftOrange = "\u{001B}[1;38;5;202m"
        let resetFg = "\u{001B}[22;39m"
        let bgColor = "\u{001B}[48;5;236m"
        let resetAll = "\u{001B}[0m"

        // Get visible slice of matched items based on scrollOffset
        let startIndex = scrollOffset
        let endIndex = min(startIndex + displayHeight, matchedItems.count)
        let visibleItems = Array(matchedItems[startIndex..<endIndex])

        var buffer = ""
        for (displayIndex, matchedItem) in visibleItems.enumerated() {
            let row = displayIndex + 3  // Start from row 3 (after input on row 1 and border on row 2)
            let actualIndex = startIndex + displayIndex

            let isSelected = selectedIndex == actualIndex
            let isMarked = selectedItems.contains(matchedItem.item.index)

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

    /// Render status bar
    private func renderStatusBar(
        matchedCount: Int,
        totalItems: Int,
        selectedItems: Set<Int>,
        isReadingStdin: Bool,
        scrollOffset: Int,
        displayHeight: Int,
        row: Int,
        cols: Int
    ) -> String {
        var status: String
        if selectedItems.isEmpty {
            status = "\(matchedCount)/\(totalItems)"
        } else {
            status = "\(matchedCount)/\(totalItems) (\(selectedItems.count) selected)"
        }

        // Show loading indicator if still reading stdin (cached value, no async)
        if isReadingStdin {
            status += " [loading...]"
        }

        // Add scroll indicator if there are more items than visible
        if matchedCount > displayHeight {
            let scrollPercent = Int((Double(scrollOffset) / Double(max(1, matchedCount - displayHeight))) * 100)
            status += " [\(scrollPercent)%]"
        }

        return "\u{001B}[\(row);1H\u{001B}[K" + TextRenderer.pad(status, width: cols)
    }
}

/// Context for rendering operations
struct RenderContext: Sendable {
    let rows: Int
    let cols: Int
    let isReadingStdin: Bool
    let showSplitPreview: Bool
    let showFloatingPreview: Bool
}
