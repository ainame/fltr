import Foundation

/// Keyboard input handling
enum Key: Equatable, Sendable {
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
    case ctrlO  // Toggle preview
    case unknown
}

/// Parse key input from raw bytes
struct KeyboardInput {
    /// Parse escape sequence or regular key
    static func parseKey(firstByte: UInt8, readNext: () -> UInt8?) -> Key {
        switch firstByte {
        case 27:  // ESC
            // Check if there's a follow-up byte for escape sequences
            guard let next = readNext() else {
                return .escape
            }

            if next == 91 {  // [ for CSI sequences
                guard let cmd = readNext() else { return .escape }
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

        case 3:  // Ctrl-C
            return .ctrlC

        case 4:  // Ctrl-D
            return .ctrlD

        case 21:  // Ctrl-U
            return .ctrlU

        case 16:  // Ctrl-P (previous/up)
            return .up

        case 14:  // Ctrl-N (next/down)
            return .down

        case 15:  // Ctrl-O (toggle preview)
            return .ctrlO

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
