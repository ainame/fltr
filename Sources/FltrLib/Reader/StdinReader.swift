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

        // Use regular Task to maintain structured concurrency and actor isolation
        return Task {
            // Read in background - readLine() is synchronous but blocks until data available
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                await cache.append(trimmed)
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
