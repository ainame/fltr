import FltrLib
import Foundation

private struct Instrument {
    let symbol: String
    let name: String
    let isin: String
}

private struct RankedCandidate {
    let score: Int
    let length: Int
    let index: Int
}

private struct MinHeap {
    private var storage: [RankedCandidate] = []

    var count: Int { storage.count }

    mutating func push(_ value: RankedCandidate) {
        storage.append(value)
        siftUp(from: storage.count - 1)
    }

    mutating func replaceMin(with value: RankedCandidate) {
        guard !storage.isEmpty else {
            push(value)
            return
        }
        storage[0] = value
        siftDown(from: 0)
    }

    func min() -> RankedCandidate? {
        storage.first
    }

    mutating func sortedDescending() -> [RankedCandidate] {
        storage.sorted(by: Self.isBetter)
    }

    private static func isWorse(_ lhs: RankedCandidate, than rhs: RankedCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        if lhs.length != rhs.length { return lhs.length > rhs.length }
        return lhs.index > rhs.index
    }

    private static func isBetter(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.length != rhs.length { return lhs.length < rhs.length }
        return lhs.index < rhs.index
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if Self.isWorse(storage[child], than: storage[parent]) {
                storage.swapAt(child, parent)
                child = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var worst = parent

            if left < storage.count, Self.isWorse(storage[left], than: storage[worst]) {
                worst = left
            }
            if right < storage.count, Self.isWorse(storage[right], than: storage[worst]) {
                worst = right
            }
            if worst == parent { return }
            storage.swapAt(parent, worst)
            parent = worst
        }
    }
}

private struct App {
    private static let topK = 10

    static func run() {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: comparison-quality-fltr <tsv-path>\n", stderr)
            exit(2)
        }

        let tsvPath = CommandLine.arguments[1]
        let matcher = FuzzyMatcher(caseSensitive: false, scheme: .path)
        let instruments = loadCorpus(from: tsvPath)

        let symbolCandidates = instruments.map(\.symbol)
        let nameCandidates = instruments.map(\.name)
        let isinCandidates = instruments.map(\.isin)

        var buffer = matcher.makeBuffer()

        while let line = readLine() {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let query = String(parts[0])
            let field = String(parts[1])
            let prepared = matcher.prepare(query)

            let pool: [String]
            switch field {
            case "symbol":
                pool = symbolCandidates
            case "isin":
                pool = isinCandidates
            default:
                pool = nameCandidates
            }

            var heap = MinHeap()

            for (idx, candidate) in pool.enumerated() {
                guard let score = scoreCandidate(candidate, matcher: matcher, prepared: prepared, buffer: &buffer) else {
                    continue
                }
                let ranked = RankedCandidate(score: score, length: candidate.utf8.count, index: idx)
                if heap.count < topK {
                    heap.push(ranked)
                } else if let currentMin = heap.min(), isBetter(ranked, than: currentMin) {
                    heap.replaceMin(with: ranked)
                }
            }

            for (rank, result) in heap.sortedDescending().enumerated() {
                let inst = instruments[result.index]
                print("\(query)\t\(field)\t\(rank + 1)\t\(result.score)\tfltr\t\(inst.symbol)\t\(inst.name)")
            }
        }
    }

    private static func scoreCandidate(
        _ candidate: String,
        matcher: FuzzyMatcher,
        prepared: PreparedPattern,
        buffer: inout MatcherScratch
    ) -> Int? {
        if prepared.lowercasedBytes.isEmpty {
            return 0
        }

        if let score = candidate.utf8.withContiguousStorageIfAvailable({
            scoreCandidateBytes(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count), matcher: matcher, prepared: prepared, buffer: &buffer)
        }) {
            return score
        }

        let bytes = Array(candidate.utf8)
        return bytes.withUnsafeBufferPointer {
            scoreCandidateBytes($0, matcher: matcher, prepared: prepared, buffer: &buffer)
        }
    }

    private static func scoreCandidateBytes(
        _ text: UnsafeBufferPointer<UInt8>,
        matcher: FuzzyMatcher,
        prepared: PreparedPattern,
        buffer: inout MatcherScratch
    ) -> Int? {
        matcher.match(prepared, textBuf: text, buffer: &buffer).map { Int($0.score) }
    }

    private static func isBetter(_ lhs: RankedCandidate, than rhs: RankedCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.length != rhs.length { return lhs.length < rhs.length }
        return lhs.index < rhs.index
    }

    private static func loadCorpus(from path: String) -> [Instrument] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        let content = String(decoding: data, as: UTF8.self)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        var instruments: [Instrument] = []
        instruments.reserveCapacity(272_000)
        for (i, line) in lines.enumerated() {
            if i == 0 { continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            if cols.count >= 3 {
                instruments.append(Instrument(symbol: String(cols[0]), name: String(cols[1]), isin: String(cols[2])))
            }
        }
        return instruments
    }
}

App.run()
