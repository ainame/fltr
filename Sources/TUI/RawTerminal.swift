import Foundation
import SystemPackage

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// TUI - A Swift Terminal User Interface library
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
    private var ttyFd: FileDescriptor?
    private let stdoutFd = FileDescriptor.standardOutput
    private var isRawMode = false

    public enum TerminalError: Error {
        case failedToGetAttributes
        case failedToSetAttributes
        case failedToGetSize
        case failedToOpenTTY
        case ioError(Errno)
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
        let fd: FileDescriptor
        do {
            fd = try FileDescriptor.open("/dev/tty", .readWrite)
        } catch {
            throw TerminalError.failedToOpenTTY
        }
        ttyFd = fd

        var raw = termios()
        guard tcgetattr(fd.rawValue, &raw) == 0 else {
            try? fd.close()
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

        guard tcsetattr(fd.rawValue, TCSAFLUSH, &raw) == 0 else {
            try? fd.close()
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
            tcsetattr(fd.rawValue, TCSAFLUSH, &original)
            try? fd.close()
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
        guard ioctl(stdoutFd.rawValue, TIOCGWINSZ, &w) == 0 else {
            throw TerminalError.failedToGetSize
        }
        return (Int(w.ws_row), Int(w.ws_col))
    }

    /// Writes a string to stdout.
    ///
    /// - Parameter string: The string to write
    public func write(_ string: String) {
        _ = try? stdoutFd.writeAll(string.utf8)
    }

    /// Flushes stdout buffer.
    public func flush() {
        // Standard C stdout works on both macOS and Linux
        fflush(stdout)
    }

    /// Reads a single byte from terminal input (non-blocking).
    ///
    /// - Returns: The byte read, or nil if no input is available
    public func readByte() -> UInt8? {
        guard let fd = ttyFd else { return nil }
        var byte: UInt8 = 0
        do {
            let bytesRead = try withUnsafeMutableBytes(of: &byte) { buffer in
                try fd.read(into: buffer)
            }
            return bytesRead == 1 ? byte : nil
        } catch {
            return nil
        }
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
