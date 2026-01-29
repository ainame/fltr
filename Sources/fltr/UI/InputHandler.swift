import Foundation
import TUI

/// Handles keyboard and mouse input parsing and routing
struct InputHandler: Sendable {
    let multiSelect: Bool
    let hasPreview: Bool
    let useFloatingPreview: Bool

    /// Parse escape sequence from terminal
    func parseEscapeSequence(firstByte: UInt8, terminal: RawTerminal) async -> Key {
        guard firstByte == 27 else {
            // Not an escape sequence, use standard parsing
            return KeyboardInput.parseKey(firstByte: firstByte, readNext: { nil })
        }

        // Check for arrow keys and other escape sequences
        guard let next = await terminal.readByte(), next == 91 else {  // '['
            return .escape
        }

        guard let cmd = await terminal.readByte() else {
            return .escape
        }

        // Handle mouse SGR mode: ESC[<...
        if cmd == 60 {  // '<'
            // Read until 'M' or 'm' to get button;col;row
            var buffer = ""
            var foundEnd = false

            // Read up to 50 bytes (safety limit)
            for _ in 0..<50 {
                if let byte = await terminal.readByte() {
                    let char = Character(UnicodeScalar(byte))
                    if char == "M" || char == "m" {
                        foundEnd = true
                        break
                    }
                    buffer.append(char)
                } else {
                    break
                }
            }

            if foundEnd {
                // Parse button;col;row
                let parts = buffer.split(separator: ";").compactMap { Int($0) }
                if parts.count == 3 {
                    let button = parts[0]
                    let col = parts[1]
                    let row = parts[2]

                    // Handle scroll events (button 64 = scroll up, 65 = scroll down)
                    switch button {
                    case 64: return .mouseScrollUp(col: col, row: row)
                    case 65: return .mouseScrollDown(col: col, row: row)
                    default: return .unknown
                    }
                }
            }

            return .unknown
        }

        // Regular arrow keys
        switch cmd {
        case 65: return .up
        case 66: return .down
        case 67: return .right
        case 68: return .left
        default: return .unknown
        }
    }

    /// Handle key event and update state, return action to take
    func handleKeyEvent(
        key: Key,
        state: inout UIState,
        context: InputContext
    ) -> InputAction {
        switch key {
        case .char(let char):
            state.addChar(char)
            return .scheduleMatchUpdate

        case .backspace:
            state.deleteChar()
            return .scheduleMatchUpdate

        case .enter:
            state.shouldExit = true
            state.exitWithSelection = true
            return .none

        case .escape, .ctrlC:
            state.shouldExit = true
            state.exitWithSelection = false
            return .none

        case .ctrlU:
            state.clearQuery()
            return .scheduleMatchUpdate

        case .ctrlK:
            state.deleteToEndOfLine()
            return .scheduleMatchUpdate

        case .ctrlA:
            state.moveCursorToStart()
            return .none

        case .ctrlE:
            state.moveCursorToEnd()
            return .none

        case .ctrlF:
            state.moveCursorRight()
            return .none

        case .ctrlB:
            state.moveCursorLeft()
            return .none

        case .left:
            state.moveCursorLeft()
            return .none

        case .right:
            state.moveCursorRight()
            return .none

        case .up:
            state.moveUp(visibleHeight: context.visibleHeight)
            return .updatePreview

        case .down:
            state.moveDown(visibleHeight: context.visibleHeight)
            return .updatePreview

        case .tab:
            if multiSelect {
                state.toggleSelection()
            }
            return .none

        case .ctrlO:
            // Toggle preview window (style depends on useFloatingPreview flag)
            if hasPreview {
                return .togglePreview
            }
            return .none

        case .mouseScrollUp(let col, let row):
            if let bounds = context.previewBounds, bounds.contains(col: col, row: row) {
                // Scroll preview up (decrease offset)
                let newOffset = max(0, context.previewScrollOffset - 3)
                return .updatePreviewScroll(offset: newOffset)
            } else {
                // Scroll list up
                state.moveUp(visibleHeight: context.visibleHeight)
                return .updatePreview
            }

        case .mouseScrollDown(let col, let row):
            if let bounds = context.previewBounds, bounds.contains(col: col, row: row) {
                // Scroll preview down (increase offset)
                let lines = context.cachedPreview.split(separator: "\n", omittingEmptySubsequences: false)
                let maxOffset = max(0, lines.count - 1)
                let newOffset = min(maxOffset, context.previewScrollOffset + 3)
                return .updatePreviewScroll(offset: newOffset)
            } else {
                // Scroll list down
                state.moveDown(visibleHeight: context.visibleHeight)
                return .updatePreview
            }

        default:
            return .none
        }
    }
}

/// Context for input handling operations
struct InputContext: Sendable {
    let visibleHeight: Int
    let cachedPreview: String
    let previewScrollOffset: Int
    let previewBounds: PreviewBounds?
}

/// Action to take after handling input
enum InputAction: Sendable {
    case none
    case scheduleMatchUpdate
    case updatePreview
    case updatePreviewScroll(offset: Int)
    case togglePreview
}
