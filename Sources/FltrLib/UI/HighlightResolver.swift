import Foundation

/// Resolves highlight positions lazily for visible rows.
/// Cache key is scoped by query + item index.
struct HighlightResolver: Sendable {
    private struct CacheKey: Hashable {
        let query: String
        let index: Item.Index
    }

    private let matcher: FuzzyMatcher
    private let capacity: Int
    private var preparedByQuery: [String: PreparedPattern] = [:]
    private var cache: [CacheKey: [UInt16]] = [:]
    private var order: [CacheKey] = []
    private var scratch: MatcherScratch

    init(matcher: FuzzyMatcher, capacity: Int = 1024) {
        self.matcher = matcher
        self.capacity = max(1, capacity)
        self.scratch = matcher.makeBuffer()
    }

    mutating func positions(query: String, item: Item, textBuffer: TextBuffer) -> [UInt16] {
        guard !query.isEmpty else { return [] }

        let key = CacheKey(query: query, index: item.index)
        if let cached = cache[key] {
            touch(key)
            return cached
        }

        let prepared: PreparedPattern
        if let existing = preparedByQuery[query] {
            prepared = existing
        } else {
            let p = matcher.prepare(query)
            preparedByQuery[query] = p
            prepared = p
        }

        let found: [UInt16] = textBuffer.withBytes { allBytes in
            let slice = UnsafeBufferPointer(
                start: allBytes.baseAddress! + Int(item.offset),
                count: Int(item.length)
            )
            return matcher.matchForHighlight(prepared, textBuf: slice, buffer: &scratch)?.positions ?? []
        }

        insert(key: key, value: found)
        return found
    }

    private mutating func touch(_ key: CacheKey) {
        guard let idx = order.firstIndex(of: key) else { return }
        order.remove(at: idx)
        order.append(key)
    }

    private mutating func insert(key: CacheKey, value: [UInt16]) {
        if cache[key] != nil {
            cache[key] = value
            touch(key)
            return
        }

        cache[key] = value
        order.append(key)

        while order.count > capacity {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}
