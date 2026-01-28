import Foundation

/// UI state management
struct UIState: Sendable {
    var query: String = ""
    var previousQuery: String = ""  // For incremental filtering optimization
    var cursorPosition: Int = 0
    var selectedIndex: Int = 0
    var scrollOffset: Int = 0  // First visible item index
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

    mutating func moveUp(visibleHeight: Int) {
        if selectedIndex > 0 {
            selectedIndex -= 1
            // Scroll up if selected item goes above visible area
            if selectedIndex < scrollOffset {
                scrollOffset = selectedIndex
            }
        }
    }

    mutating func moveDown(visibleHeight: Int) {
        if selectedIndex < matchedItems.count - 1 {
            selectedIndex += 1
            // Scroll down if selected item goes below visible area
            let lastVisibleIndex = scrollOffset + visibleHeight - 1
            if selectedIndex > lastVisibleIndex {
                scrollOffset = selectedIndex - visibleHeight + 1
            }
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
        // Reset scroll to top when matches change
        scrollOffset = 0
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
