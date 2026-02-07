import Foundation
import TUI

/// Example of declarative TUI usage
struct DeclarativeExample {
    static func exampleView(spinnerFrame: Int) -> any TUIView {
        VStack(spacing: 1) {
            Text("Declarative TUI Demo")
                .bold()
                .foregroundColor(ANSIColors.swiftOrange)
            
            Divider()
            
            HStack(spacing: 2) {
                SpinnerView(frame: spinnerFrame)
                Text("Loading...")
            }
            
            Spacer()
            
            Text("Built with SwiftUI-style declarative syntax")
                .foregroundColor(ANSIColors.dim)
        }
    }
}
