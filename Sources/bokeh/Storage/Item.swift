import Foundation

/// Represents a single item in the fuzzy finder
struct Item: Sendable {
    let index: Int
    let text: String

    init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}
