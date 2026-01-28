import Foundation
import DisplayWidth

/// Text rendering utilities for terminal
struct TextRenderer {
    private static let displayWidth = DisplayWidth()

    /// Truncate text to fit width, considering Unicode display width
    static func truncate(_ text: String, width: Int) -> String {
        var currentWidth = 0
        var result = ""

        for char in text {
            let charWidth = displayWidth(char)
            if currentWidth + charWidth > width {
                break
            }
            result.append(char)
            currentWidth += charWidth
        }

        return result
    }

    /// Pad text to exact width with spaces
    static func pad(_ text: String, width: Int) -> String {
        let currentWidth = displayWidth(text)
        if currentWidth >= width {
            return truncate(text, width: width)
        }

        let padding = String(repeating: " ", count: width - currentWidth)
        return text + padding
    }

    /// Highlight matched positions in text
    static func highlight(_ text: String, positions: [Int]) -> String {
        guard !positions.isEmpty else { return text }

        var result = ""
        let chars = Array(text)
        let posSet = Set(positions)

        for (index, char) in chars.enumerated() {
            if posSet.contains(index) {
                // Highlight with bold + green, preserve background
                result += "\u{001B}[1;32m\(char)\u{001B}[22;39m"
            } else {
                result.append(char)
            }
        }

        return result
    }

    /// Truncate text and then apply highlighting (ANSI-safe)
    /// This ensures ANSI escape sequences don't break width calculation
    static func truncateAndHighlight(_ text: String, positions: [Int], width: Int) -> String {
        // First truncate to fit width
        var currentWidth = 0
        var truncatedLength = 0

        for char in text {
            let charWidth = displayWidth(char)
            if currentWidth + charWidth > width {
                break
            }
            currentWidth += charWidth
            truncatedLength += 1
        }

        // Get truncated text
        let truncatedText = String(text.prefix(truncatedLength))

        // Filter positions to only include those within truncated range
        let validPositions = positions.filter { $0 < truncatedLength }

        // Apply highlighting to truncated text
        return highlight(truncatedText, positions: validPositions)
    }

    /// Pad text that may contain ANSI codes to exact width
    /// Strips ANSI codes to calculate visual width, then pads with spaces
    static func padWithoutANSI(_ text: String, width: Int) -> String {
        // Strip ANSI codes to calculate actual display width
        let stripped = stripANSI(text)
        let currentWidth = displayWidth(stripped)

        if currentWidth >= width {
            return text
        }

        let padding = String(repeating: " ", count: width - currentWidth)
        return text + padding
    }

    /// Strip ANSI escape sequences from text
    private static func stripANSI(_ text: String) -> String {
        var result = ""
        var inEscape = false

        for char in text {
            if char == "\u{001B}" {
                inEscape = true
            } else if inEscape {
                if char == "m" {
                    inEscape = false
                }
            } else {
                result.append(char)
            }
        }

        return result
    }
}
