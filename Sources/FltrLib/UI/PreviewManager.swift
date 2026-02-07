import Foundation
import TUI
import Subprocess

/// Manages preview command execution and rendering
struct PreviewManager: Sendable {
    let command: String?
    let useFloatingPreview: Bool

    /// Execute preview command with item text substitution
    func executeCommand(_ command: String, item: String) async -> String {
        // Replace {} with item text, shell-escape it
        let escapedItem = item.replacingOccurrences(of: "'", with: "'\\''")
        let expandedCommand = command.replacingOccurrences(of: "{}", with: "'\(escapedItem)'")

        // Execute via shell with timeout using throwing task group to avoid race condition
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    // Execute command using swift-subprocess
                    let result = try await run(
                        .name("/bin/sh"),
                        arguments: ["-c", expandedCommand],
                        output: .string(limit: 1_000_000),  // 1MB limit
                        error: .discarded
                    )

                    // Get output string (may be nil if decoding fails)
                    guard let output = result.standardOutput else {
                        return ""
                    }

                    // Limit lines
                    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                    if lines.count > 1000 {
                        return lines.prefix(1000).joined(separator: "\n") + "\n\n[Output truncated - showing first 1000 lines]"
                    }
                    return output
                }

                // Timeout task that throws to distinguish from command completion
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw TimeoutError()
                }

                // Return first completed result, cancel the other
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch is TimeoutError {
            return "[Preview timeout - command took too long]"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Error type to distinguish timeout from command failures
    private struct TimeoutError: Error {}

    /// Render split-screen preview (fzf style)
    func renderSplitPreview(
        content: String,
        scrollOffset: Int,
        startRow: Int,
        endRow: Int,
        startCol: Int,
        width: Int
    ) -> String {
        guard command != nil else { return "" }

        var buffer = ""
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let maxLines = endRow - startRow + 1

        // Draw vertical separator
        for row in startRow...endRow {
            buffer += ANSIColors.moveCursor(row: row, col: startCol - 1)
            buffer += ANSIColors.swiftOrange + "│" + ANSIColors.reset
        }

        // Draw preview content with scroll offset
        for i in 0..<maxLines {
            let row = startRow + i
            let lineIndex = scrollOffset + i

            buffer += ANSIColors.moveCursor(row: row, col: startCol) + ANSIColors.clearLineToEnd

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
    func renderFloatingPreview(
        content: String,
        scrollOffset: Int,
        itemName: String,
        rows: Int,
        cols: Int
    ) -> (bounds: Bounds?, buffer: String) {
        guard command != nil else { return (nil, "") }

        // Calculate window dimensions (80% of screen, centered)
        let windowWidth = Int(Double(cols) * 0.8)
        let windowHeight = Int(Double(rows) * 0.7)
        let startRow = (rows - windowHeight) / 2
        let startCol = (cols - windowWidth) / 2
        let endRow = startRow + windowHeight - 1
        let endCol = startCol + windowWidth - 1
        let bounds = Bounds(
            startRow: startRow,
            endRow: endRow,
            startCol: startCol,
            endCol: endCol
        )

        var buffer = ""
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        // Replace tabs and truncate title to avoid width issues
        let sanitizedName = itemName.replacingOccurrences(of: "\t", with: " ")
        let maxTitleLength = windowWidth - 16  // Leave room for padding and borders
        let truncatedName = TextRenderer.truncate(sanitizedName, width: maxTitleLength)
        let title = " Preview: \(truncatedName) "

        // Clear and draw each line of the window
        for i in 0..<windowHeight {
            let row = startRow + i

            // Position cursor and clear entire line first
            buffer += ANSIColors.moveCursor(row: row, col: startCol) + ANSIColors.clearLineToEnd

            if i == 0 {
                // Top border with title (left-aligned with 2-char left margin)
                let titleLeftMargin = 2
                let leftBorder = String(repeating: "─", count: titleLeftMargin)
                let rightBorder = String(repeating: "─", count: max(0, windowWidth - title.count - titleLeftMargin - 2))
                buffer += ANSIColors.swiftOrange + "┌" + leftBorder + ANSIColors.reset + title + ANSIColors.swiftOrange + rightBorder + "┐" + ANSIColors.reset

            } else if i == windowHeight - 1 {
                // Bottom border with help text (centered)
                let helpText = " Ctrl-O to close "
                let helpLeftMargin = (windowWidth - helpText.count - 2) / 2
                let bottomLeft = String(repeating: "─", count: max(0, helpLeftMargin))
                let bottomRight = String(repeating: "─", count: max(0, windowWidth - helpLeftMargin - helpText.count - 2))
                buffer += ANSIColors.swiftOrange + "└" + bottomLeft + ANSIColors.reset + helpText + ANSIColors.swiftOrange + bottomRight + "┘" + ANSIColors.reset

            } else {
                // Content line with left/right borders (single line)
                let contentWidth = windowWidth - 2
                let contentIndex = i - 1
                let lineIndex = scrollOffset + contentIndex

                buffer += ANSIColors.swiftOrange + "│" + ANSIColors.reset

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

                buffer += ANSIColors.swiftOrange + "│" + ANSIColors.reset
            }
        }

        return (bounds, buffer)
    }
}

/// Type alias for preview window bounds (now using TUI.Bounds)
public typealias PreviewBounds = Bounds
