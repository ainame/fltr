import Foundation

/// Keyboard input parsing for terminal applications.
///
/// Converts raw byte sequences into structured key events, handling:
/// - ASCII characters
/// - Control keys (Ctrl-C, Ctrl-D, etc.)
/// - Arrow keys and escape sequences
/// - Special keys (Tab, Enter, Backspace, etc.)
/// - Mouse events (scroll up/down with position)
public enum Key: Equatable, Sendable {
    case char(Character)
    case backspace
    case delete
    case enter
    case escape
    case tab
    case up
    case down
    case left
    case right
    case ctrlC
    case ctrlD
    case ctrlU
    case ctrlK  // Kill line (delete from cursor to end)
    case ctrlO  // Toggle preview
    case ctrlA  // Move to beginning of line
    case ctrlE  // Move to end of line
    case ctrlF  // Move forward one character
    case ctrlB  // Move backward one character
    case mouseScrollUp(col: Int, row: Int)
    case mouseScrollDown(col: Int, row: Int)
    case unknown
}

/// Parse key input from raw bytes
public struct KeyboardInput {
    /// Parses a key from raw byte input.
    ///
    /// - Parameters:
    ///   - firstByte: The first byte of input
    ///   - readNext: Closure to read additional bytes for escape sequences
    /// - Returns: The parsed Key value
    public static func parseKey(firstByte: UInt8, readNext: () -> UInt8?) -> Key {
        switch firstByte {
        case 27:  // ESC
            // Check if there's a follow-up byte for escape sequences
            guard let next = readNext() else {
                return .escape
            }

            if next == 91 {  // [ for CSI sequences
                guard let cmd = readNext() else { return .escape }

                // Check for mouse SGR mode: ESC[<...
                if cmd == 60 {  // '<' - SGR mouse mode
                    // Read until 'M' or 'm' to get button;col;row
                    var buffer = ""
                    while let byte = readNext() {
                        let char = Character(UnicodeScalar(byte))
                        if char == "M" || char == "m" {
                            // Parse button;col;row
                            let parts = buffer.split(separator: ";").compactMap { Int($0) }
                            guard parts.count == 3 else { return .unknown }
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
                        buffer.append(char)
                    }
                    return .unknown
                }

                switch cmd {
                case 65: return .up      // ESC[A
                case 66: return .down    // ESC[B
                case 67: return .right   // ESC[C
                case 68: return .left    // ESC[D
                default: return .unknown
                }
            }
            return .escape

        case 127, 8:  // DEL or BS
            return .backspace

        case 9:  // TAB
            return .tab

        case 10, 13:  // LF or CR
            return .enter

        case 1:  // Ctrl-A
            return .ctrlA

        case 2:  // Ctrl-B
            return .ctrlB

        case 3:  // Ctrl-C
            return .ctrlC

        case 4:  // Ctrl-D
            return .ctrlD

        case 5:  // Ctrl-E
            return .ctrlE

        case 6:  // Ctrl-F
            return .ctrlF

        case 11:  // Ctrl-K
            return .ctrlK

        case 14:  // Ctrl-N (next/down)
            return .down

        case 15:  // Ctrl-O (toggle preview)
            return .ctrlO

        case 16:  // Ctrl-P (previous/up)
            return .up

        case 21:  // Ctrl-U
            return .ctrlU

        case 32...126:  // Printable ASCII
            return .char(Character(UnicodeScalar(firstByte)))

        default:
            // Non-printable control characters should be ignored
            if firstByte < 32 {
                return .unknown
            }
            // Try to interpret as UTF-8
            let scalar = UnicodeScalar(firstByte)
            return .char(Character(scalar))
        }
    }
}
