import Foundation
import DeclarativeTUI

@main
struct DeclarativeDemo {
    static func main() async {
        do {
            let app = App(rootView:
                VStack(spacing: 2) {
                    Text("🚀 Declarative TUI Proof of Concept")
                        .bold()
                        .foregroundColor(Colors.orange)

                    Divider()

                    Text("This UI is built with:")
                        .foregroundColor(Colors.dim)

                    Text("  • SwiftUI-style result builders")
                    Text("  • VStack and HStack layouts")
                    Text("  • Chainable modifiers (.bold(), .foregroundColor())")
                    Text("  • Type-safe view composition")

                    Text("")  // Spacer line

                    Divider(style: .dashed)

                    Text("Press ESC or 'q' to exit")
                        .foregroundColor(Colors.dim)
                }
            )

            try await app.run()
        } catch {
            print("Error: \(error)")
        }
    }
}
