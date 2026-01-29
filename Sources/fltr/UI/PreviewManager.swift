import Foundation
import TUI

/// Manages preview command execution and rendering
struct PreviewManager: Sendable {
    let command: String?
    let useFloatingPreview: Bool

    /// Execute preview command with item text substitution
    func executeCommand(_ command: String, item: String) async -> String {
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
            let lineIndex = scrollOffset + i

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
    func renderFloatingPreview(
        content: String,
        scrollOffset: Int,
        itemName: String,
        rows: Int,
        cols: Int
    ) -> (bounds: PreviewBounds?, buffer: String) {
        guard command != nil else { return (nil, "") }

        // Calculate window dimensions (80% of screen, centered)
        let windowWidth = Int(Double(cols) * 0.8)
        let windowHeight = Int(Double(rows) * 0.7)
        let startRow = (rows - windowHeight) / 2
        let startCol = (cols - windowWidth) / 2
        let endRow = startRow + windowHeight - 1
        let endCol = startCol + windowWidth - 1
        let bounds = PreviewBounds(
            startRow: startRow,
            endRow: endRow,
            startCol: startCol,
            endCol: endCol
        )

        // Swift orange for borders
        let borderColor = "\u{001B}[1;38;5;202m"
        let resetColor = "\u{001B}[0m"

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
                let lineIndex = scrollOffset + contentIndex

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

/// Preview window bounds for mouse hit testing (1-indexed, inclusive)
struct PreviewBounds: Sendable {
    let startRow: Int
    let endRow: Int
    let startCol: Int
    let endCol: Int

    /// Check if position is within bounds
    func contains(col: Int, row: Int) -> Bool {
        return row >= startRow && row <= endRow &&
               col >= startCol && col <= endCol
    }
}
