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
                // Highlight with reverse video
                result += "\u{001B}[7m\(char)\u{001B}[27m"
            } else {
                result.append(char)
            }
        }

        return result
    }
}
