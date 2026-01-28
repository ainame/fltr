import Foundation
import SystemPackage

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Terminal control using raw mode
actor RawTerminal {
    private var originalTermios: termios?
    private var ttyFd: Int32?
    private let stdout: Int32 = STDOUT_FILENO
    private var isRawMode = false

    enum TerminalError: Error {
        case failedToGetAttributes
        case failedToSetAttributes
        case failedToGetSize
        case failedToOpenTTY
    }

    /// Enter raw mode and alternate screen
    func enterRawMode() throws {
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

    /// Exit raw mode and restore terminal
    func exitRawMode() {
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

    /// Get terminal size
    func getSize() throws -> (rows: Int, cols: Int) {
        var w = winsize()
        guard ioctl(stdout, TIOCGWINSZ, &w) == 0 else {
            throw TerminalError.failedToGetSize
        }
        return (Int(w.ws_row), Int(w.ws_col))
    }

    /// Write string to stdout
    func write(_ string: String) {
        _ = string.withCString { ptr in
            Darwin.write(stdout, ptr, strlen(ptr))
        }
    }

    /// Flush stdout
    func flush() {
        fflush(__stdoutp)
    }

    /// Read single byte (non-blocking)
    func readByte() -> UInt8? {
        guard let fd = ttyFd else { return nil }
        var byte: UInt8 = 0
        let result = Darwin.read(fd, &byte, 1)
        return result == 1 ? byte : nil
    }

    /// Move cursor to position (1-indexed)
    func moveCursor(row: Int, col: Int) {
        write("\u{001B}[\(row);\(col)H")
    }

    /// Clear from cursor to end of screen
    func clearToEnd() {
        write("\u{001B}[J")
    }

    /// Clear current line
    func clearLine() {
        write("\u{001B}[2K")
    }

    // Note: deinit cannot be async, so cleanup must be done explicitly via exitRawMode()
}
