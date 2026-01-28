import Foundation

/// UI state management
struct UIState: Sendable {
    var query: String = ""
    var cursorPosition: Int = 0
    var selectedIndex: Int = 0
    var selectedItems: Set<Int> = []
    var matchedItems: [MatchedItem] = []
    var totalItems: Int = 0
    var shouldExit: Bool = false
    var exitWithSelection: Bool = false

    mutating func addChar(_ char: Character) {
        query.append(char)
        cursorPosition = query.count
    }

    mutating func deleteChar() {
        guard !query.isEmpty else { return }
        query.removeLast()
        cursorPosition = query.count
    }

    mutating func clearQuery() {
        query = ""
        cursorPosition = 0
    }

    mutating func moveUp() {
        if selectedIndex > 0 {
            selectedIndex -= 1
        }
    }

    mutating func moveDown() {
        if selectedIndex < matchedItems.count - 1 {
            selectedIndex += 1
        }
    }

    mutating func toggleSelection() {
        guard selectedIndex < matchedItems.count else { return }
        let itemIndex = matchedItems[selectedIndex].item.index

        if selectedItems.contains(itemIndex) {
            selectedItems.remove(itemIndex)
        } else {
            selectedItems.insert(itemIndex)
        }
    }

    mutating func updateMatches(_ items: [MatchedItem]) {
        matchedItems = items
        if selectedIndex >= items.count {
            selectedIndex = max(0, items.count - 1)
        }
    }

    func getSelectedItems() -> [Item] {
        if !exitWithSelection {
            return []
        }

        if selectedItems.isEmpty {
            // Return current item if nothing explicitly selected
            if selectedIndex < matchedItems.count {
                return [matchedItems[selectedIndex].item]
            }
            return []
        }

        // Return all selected items in original order
        return matchedItems
            .map { $0.item }
            .filter { selectedItems.contains($0.index) }
            .sorted { $0.index < $1.index }
    }
}
