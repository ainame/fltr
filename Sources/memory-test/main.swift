import Foundation
import FltrLib

// Memory test - load data and measure memory without UI

print("Starting memory test...")
print("PID: \(ProcessInfo.processInfo.processIdentifier)")

// Create cache and load data
let cache = ItemCache()

print("Reading from stdin...")
let startTime = Date()

// Read all lines from stdin
var lineCount = 0
var byteCount = 0
while let line = readLine() {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        Task {
            await cache.registerItem(text: trimmed)
        }
        lineCount += 1
        byteCount += trimmed.utf8.count
    }
}

let elapsed = Date().timeIntervalSince(startTime)
print("Read \(lineCount) lines, \(byteCount) bytes in \(String(format: "%.2f", elapsed))s")

// Seal and shrink
Task {
    await cache.sealAndShrink()

    let count = await cache.itemCount()
    print("ItemCache has \(count) items")

    // Keep alive for profiling
    print("")
    print("Memory loaded. Ready for profiling.")
    print("Press Ctrl+C to exit, or run in another terminal:")
    print("  ps -o pid,rss,vsz,command -p \(ProcessInfo.processInfo.processIdentifier)")
    print("  heap \(ProcessInfo.processInfo.processIdentifier)")
    print("  vmmap \(ProcessInfo.processInfo.processIdentifier)")
    print("")

    // Sleep forever
    while true {
        sleep(1000)
    }
}

RunLoop.main.run()
