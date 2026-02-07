import Foundation

/// ANSI escape code utilities for terminal colors and styling.
///
/// Provides constants and helpers for common ANSI color codes and text styling.
/// These codes work with most modern terminals that support ANSI escape sequences.
public struct ANSIColors {
    // MARK: - Basic Colors

    /// Reset all attributes to default
    public static let reset = "\u{001B}[0m"

    /// Bold text
    public static let bold = "\u{001B}[1m"

    /// Dim/faint text
    public static let dim = "\u{001B}[2m"

    /// Reverse video (swap foreground and background)
    public static let reverse = "\u{001B}[7m"

    /// Normal intensity (cancel bold/dim)
    public static let normalIntensity = "\u{001B}[22m"

    /// Normal video (cancel reverse)
    public static let normalVideo = "\u{001B}[27m"

    // MARK: - Foreground Colors

    /// Reset foreground color to default
    public static let resetForeground = "\u{001B}[39m"

    /// Black foreground
    public static let black = "\u{001B}[30m"

    /// Red foreground
    public static let red = "\u{001B}[31m"

    /// Green foreground
    public static let green = "\u{001B}[32m"

    /// Yellow foreground
    public static let yellow = "\u{001B}[33m"

    /// Blue foreground
    public static let blue = "\u{001B}[34m"

    /// Magenta foreground
    public static let magenta = "\u{001B}[35m"

    /// Cyan foreground
    public static let cyan = "\u{001B}[36m"

    /// White foreground
    public static let white = "\u{001B}[37m"

    // MARK: - Background Colors

    /// Reset background color to default
    public static let resetBackground = "\u{001B}[49m"

    /// Gray background (256-color)
    public static let grayBackground = "\u{001B}[48;5;236m"

    // MARK: - Extended Colors (256-color palette)

    /// Swift orange (256-color, #F05138 approximation)
    public static let swiftOrange = "\u{001B}[1;38;5;202m"

    /// Bold green for highlighting
    public static let highlightGreen = "\u{001B}[1;32m"

    // MARK: - Control Sequences

    /// Clear entire screen
    public static let clearScreen = "\u{001B}[2J"

    /// Clear line from cursor to end
    public static let clearLineToEnd = "\u{001B}[K"

    // MARK: - Helper Functions

    /// Move cursor to specified position (1-indexed).
    ///
    /// - Parameters:
    ///   - row: Row number (1-indexed)
    ///   - col: Column number (1-indexed)
    /// - Returns: ANSI escape sequence to move cursor
    public static func moveCursor(row: Int, col: Int) -> String {
        return "\u{001B}[\(row);\(col)H"
    }

    /// Set foreground color using 256-color palette.
    ///
    /// - Parameter color: Color code (0-255)
    /// - Returns: ANSI escape sequence
    public static func foreground256(_ color: Int) -> String {
        return "\u{001B}[38;5;\(color)m"
    }

    /// Set background color using 256-color palette.
    ///
    /// - Parameter color: Color code (0-255)
    /// - Returns: ANSI escape sequence
    public static func background256(_ color: Int) -> String {
        return "\u{001B}[48;5;\(color)m"
    }

    /// Apply a style to text and reset afterward.
    ///
    /// - Parameters:
    ///   - text: The text to style
    ///   - style: The ANSI style code
    /// - Returns: Styled text with reset
    public static func styled(_ text: String, with style: String) -> String {
        return style + text + reset
    }
}
