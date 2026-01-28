import Foundation
import SystemPackage

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// SwiftTUI - A Swift Terminal User Interface library
///
/// `RawTerminal` provides low-level terminal control functionality including:
/// - Raw mode activation/deactivation
/// - Alternate screen buffer management
/// - Cursor control and positioning
/// - Terminal size detection
/// - Non-blocking byte reading
///
/// This actor is designed for safe concurrent access to terminal I/O operations.
public actor RawTerminal {
    private var originalTermios: termios?
    private var ttyFd: Int32?
    private let stdout: Int32 = STDOUT_FILENO
    private var isRawMode = false

    public enum TerminalError: Error {
        case failedToGetAttributes
        case failedToSetAttributes
        case failedToGetSize
        case failedToOpenTTY
    }

    public init() {}

    /// Enters raw terminal mode and activates the alternate screen buffer.
    ///
    /// Raw mode disables canonical input processing and echo, allowing character-by-character
    /// input reading. The alternate screen buffer preserves the original terminal content.
    ///
    /// - Throws: `TerminalError.failedToOpenTTY` if /dev/tty cannot be opened
    ///           `TerminalError.failedToGetAttributes` if terminal attributes cannot be read
    ///           `TerminalError.failedToSetAttributes` if raw mode cannot be activated
    ///
    /// - Note: Always call `exitRawMode()` to restore terminal state, preferably in a defer block
    public func enterRawMode() throws {
        guard !isRawMode else { return }

        // Open /dev/tty for keyboard input (works even when stdin is piped)
        let fd = open("/dev/tty", O_RDWR)
        guard fd >= 0 else {
            throw TerminalError.failedToOpenTTY
        }
        ttyFd = fd

        var raw = termios()
        guard tcgetattr(fd, &raw) == 0 else {
            close(fd)
            throw TerminalError.failedToGetAttributes
        }

        originalTermios = raw

        // Disable canonical mode, echo, and signals
        raw.c_lflag &= ~(UInt(ECHO | ICANON | ISIG | IEXTEN))
        // Disable input processing
        raw.c_iflag &= ~(UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP))
        // Disable output processing
        raw.c_oflag &= ~(UInt(OPOST))
        // Set character size
        raw.c_cflag |= UInt(CS8)

        // Non-blocking read with timeout
        raw.c_cc.16 = 0  // VMIN = 0
        raw.c_cc.17 = 1  // VTIME = 1 (100ms)

        guard tcsetattr(fd, TCSAFLUSH, &raw) == 0 else {
            close(fd)
            throw TerminalError.failedToSetAttributes
        }

        // Enter alternate screen buffer
        write("\u{001B}[?1049h")
        // Hide cursor
        write("\u{001B}[?25l")
        // Clear screen
        write("\u{001B}[2J")
        flush()

        isRawMode = true
    }

    /// Exits raw mode and restores original terminal state.
    ///
    /// Restores the terminal to its original state before entering raw mode,
    /// exits the alternate screen buffer, and shows the cursor.
    public func exitRawMode() {
        guard isRawMode else { return }

        // Show cursor
        write("\u{001B}[?25h")
        // Exit alternate screen buffer
        write("\u{001B}[?1049l")
        flush()

        if let fd = ttyFd, var original = originalTermios {
            tcsetattr(fd, TCSAFLUSH, &original)
            close(fd)
        }

        isRawMode = false
        ttyFd = nil
    }

    /// Gets the current terminal size.
    ///
    /// - Returns: A tuple containing (rows, cols) of the terminal
    /// - Throws: `TerminalError.failedToGetSize` if size cannot be determined
    public func getSize() throws -> (rows: Int, cols: Int) {
        var w = winsize()
        guard ioctl(stdout, TIOCGWINSZ, &w) == 0 else {
            throw TerminalError.failedToGetSize
        }
        return (Int(w.ws_row), Int(w.ws_col))
    }

    /// Writes a string to stdout.
    ///
    /// - Parameter string: The string to write
    public func write(_ string: String) {
        _ = string.withCString { ptr in
            Darwin.write(stdout, ptr, strlen(ptr))
        }
    }

    /// Flushes stdout buffer.
    public func flush() {
        fflush(__stdoutp)
    }

    /// Reads a single byte from terminal input (non-blocking).
    ///
    /// - Returns: The byte read, or nil if no input is available
    public func readByte() -> UInt8? {
        guard let fd = ttyFd else { return nil }
        var byte: UInt8 = 0
        let result = Darwin.read(fd, &byte, 1)
        return result == 1 ? byte : nil
    }

    /// Moves cursor to the specified position (1-indexed).
    ///
    /// - Parameters:
    ///   - row: Row number (1-based)
    ///   - col: Column number (1-based)
    public func moveCursor(row: Int, col: Int) {
        write("\u{001B}[\(row);\(col)H")
    }

    /// Clears from cursor to end of screen.
    public func clearToEnd() {
        write("\u{001B}[J")
    }

    /// Clears the current line.
    public func clearLine() {
        write("\u{001B}[2K")
    }

    // Note: deinit cannot be async, so cleanup must be done explicitly via exitRawMode()
}
