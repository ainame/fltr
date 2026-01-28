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

        return Task.detached { [weak cache] in
            // Read in background thread to avoid blocking
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if let cache = cache {
                    await cache.append(trimmed)
                }
            }

            // Mark as complete when stdin is exhausted
            await self.markComplete()
        }
    }

    private func markComplete() {
        isComplete = true
    }

    /// Check if reading is complete
    func readingComplete() -> Bool {
        return isComplete
    }
}
