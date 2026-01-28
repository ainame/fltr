import Foundation

/// Reads items from stdin
actor StdinReader {
    private let cache: ItemCache

    init(cache: ItemCache) {
        self.cache = cache
    }

    /// Read all lines from stdin into cache
    func readAll() async throws {
        // Use standard Swift line reading
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            await cache.append(trimmed)
        }
    }
}
