import Foundation

/// A horizontal separator/border widget for terminal UIs.
///
/// Provides customizable horizontal lines using box-drawing characters.
public struct HorizontalSeparator: Sendable {
    /// Box-drawing character style
    public enum Style: Sendable {
        /// Light single line: ─
        case light
        /// Heavy single line: ━
        case heavy
        /// Double line: ═
        case double
        /// Dashed line: ┄
        case dashed
        /// Custom character
        case custom(Character)
        
        var character: Character {
            switch self {
            case .light: return "─"
            case .heavy: return "━"
            case .double: return "═"
            case .dashed: return "┄"
            case .custom(let char): return char
            }
        }
    }
    
    private let style: Style
    private let color: String
    
    /// Initialize a horizontal separator.
    ///
    /// - Parameters:
    ///   - style: The box-drawing style (default: .light)
    ///   - color: ANSI color code (default: dim)
    public init(style: Style = .light, color: String = ANSIColors.dim) {
        self.style = style
        self.color = color
    }
    
    /// Render the separator at the specified position.
    ///
    /// - Parameters:
    ///   - row: Terminal row (1-indexed)
    ///   - width: Width in columns
    /// - Returns: ANSI-formatted string for the separator
    public func render(row: Int, width: Int) -> String {
        let line = String(repeating: style.character, count: max(0, width - 1))
        return ANSIColors.moveCursor(row: row, col: 1) + 
               color + line + ANSIColors.reset + 
               ANSIColors.clearLineToEnd
    }
}
