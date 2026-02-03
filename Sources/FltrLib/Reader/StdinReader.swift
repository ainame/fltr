import Foundation

/// Reads items from stdin
actor StdinReader {
    private let cache: ItemCache
    private var isReading = false
    private(set) var isComplete = false

    init(cache: ItemCache) {
        self.cache = cache
    }

    /// Start reading lines from stdin in the background
    /// Returns immediately so UI can start while reading continues
    func startReading() -> Task<Void, Never> {
        guard !isReading else {
            return Task { }
        }

        isReading = true

        // Use Task.detached so the blocking readLine() loop runs on a plain OS thread
        // and does not starve Swift's cooperative thread pool or hold the actor executor.
        return Task.detached {
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                await self.cache.append(trimmed)
            }

            // Mark as complete when stdin is exhausted
            await self.finishReading()
        }
    }

    func finishReading() async {
        isComplete = true
    }

    /// Check if reading is complete
    func readingComplete() -> Bool {
        return isComplete
    }
}
