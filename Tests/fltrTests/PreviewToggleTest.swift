import Foundation
import Testing
@testable import FltrLib

@Test("Ctrl-O toggles split preview visibility")
func ctrlOTogglesSplitPreview() async throws {
    let cache = ItemCache()
    await cache.append("apple")
    await cache.append("banana")

    let reader = StdinReader(cache: cache)
    await reader.finishReading()

    let terminal = TestTerminal(rows: 24, cols: 80)
    let ui = UIController(
        terminal: terminal,
        matcher: FuzzyMatcher(caseSensitive: false),
        cache: cache,
        reader: reader,
        maxHeight: nil,
        multiSelect: false,
        previewCommand: "echo hello {}",
        useFloatingPreview: false,
        debounceDelay: .milliseconds(10)
    )

    let runTask = Task { try await ui.run() }

    // Wait for initial render
    try await Task.sleep(for: .milliseconds(50))

    // Grab initial output — preview should NOT be visible (starts hidden)
    let beforeToggle = await terminal.output
    print("=== BEFORE Ctrl-O ===")
    print("output length: \(beforeToggle.count)")
    // The split separator "│" should NOT appear yet
    let hasSplitBefore = beforeToggle.contains("│")
    print("has split separator before: \(hasSplitBefore)")

    // Clear output so we can isolate what the next render produces
    await terminal.clearOutput()

    // Send Ctrl-O (byte 15)
    await terminal.enqueue(bytes: [15])
    // Wait for the toggle + preview command execution + render
    try await Task.sleep(for: .milliseconds(200))

    let afterToggle = await terminal.output
    print("=== AFTER Ctrl-O ===")
    print("output length: \(afterToggle.count)")
    let hasSplitAfter = afterToggle.contains("│")
    print("has split separator after: \(hasSplitAfter)")
    print("contains 'hello': \(afterToggle.contains("hello"))")

    // Now send Ctrl-O again to hide
    await terminal.clearOutput()
    await terminal.enqueue(bytes: [15])
    try await Task.sleep(for: .milliseconds(100))

    let afterHide = await terminal.output
    print("=== AFTER second Ctrl-O (hide) ===")
    print("output length: \(afterHide.count)")
    // After hiding, a full-width render should fire (no split)
    // The separator should not appear in this render
    let hasSplitAfterHide = afterHide.contains("│")
    print("has split separator after hide: \(hasSplitAfterHide)")

    // Exit
    await terminal.enqueue(bytes: [27])  // Escape to quit
    try await Task.sleep(for: .milliseconds(50))
    _ = try await runTask.value

    // Assertions
    #expect(hasSplitBefore == false, "Preview should start hidden")
    #expect(hasSplitAfter == true,   "Ctrl-O should show the split preview")
}
