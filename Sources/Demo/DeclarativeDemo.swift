import Foundation
import TUI
import SystemPackage

@main
struct DeclarativeDemo {
    static func main() async {
        do {
            let app = DeclarativeApp()
            try await app.run()
        } catch RawTerminal.TerminalError.failedToOpenTTY {
            print("Error: This demo requires a TTY (terminal) to run.")
            print("Please run it directly in your terminal, not through a pipe or redirect.")
        } catch {
            print("Error: \(error)")
        }
    }
}

actor DeclarativeApp {
    private var spinnerFrame = 0

    func run() async throws {
        let terminal = RawTerminal()
        try await terminal.enterRawMode()

        defer {
            Task {
                await terminal.exitRawMode()
            }
        }

        // Initial render
        try await render(terminal: terminal)

        // Animation task
        let animationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self.spinnerFrame += 1
                try? await self.render(terminal: terminal)
            }
        }

        // Main event loop
        while true {
            guard let byte = await terminal.readByte() else {
                if await terminal.ttyBroken {
                    break
                }
                continue
            }

            // Exit on ESC, Ctrl-C, or 'q'
            if byte == 27 || byte == 3 || byte == 113 {
                break
            }
        }

        animationTask.cancel()
    }

    private func render(terminal: any Terminal) async throws {
        let (rows, cols) = try await terminal.getSize()

        // Build the view declaratively
        let view = VStack(spacing: 2) {
            Text("🚀 Declarative TUI Proof of Concept")
                .bold()
                .foregroundColor(ANSIColors.swiftOrange)

            Divider()

            HStack(spacing: 2) {
                SpinnerView(frame: spinnerFrame)
                Text("Loading with declarative syntax...")
            }

            Text("")  // Spacer line

            Text("This UI is built with:")
                .foregroundColor(ANSIColors.dim)

            Text("  • SwiftUI-style result builders")
            Text("  • VStack and HStack layouts")
            Text("  • Chainable modifiers (.bold(), .foregroundColor())")
            Text("  • Type-safe view composition")

            Text("")  // Spacer line

            Divider(style: .dashed)

            Text("Press ESC or 'q' to exit")
                .foregroundColor(ANSIColors.dim)
        }

        // Render the view
        let context = RenderContext(
            startRow: 3,
            startCol: 4,
            maxWidth: cols - 8,
            maxHeight: rows - 6
        )

        var buffer = ANSIColors.clearScreen
        buffer += view.render(in: context)

        await terminal.write(buffer)
        await terminal.flush()
    }
}
