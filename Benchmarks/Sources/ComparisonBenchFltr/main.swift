import FltrLib
import Foundation

private struct Instrument {
    let symbol: String
    let name: String
    let isin: String
}

private struct Query {
    let text: String
    let field: String
    let category: String
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

    private static func isWorse(_ lhs: RankedCandidate, than rhs: RankedCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        if lhs.length != rhs.length { return lhs.length > rhs.length }
        return lhs.index > rhs.index
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

@main
private struct App {
    private static let topK = 100
    private static let categoryOrder = [
        "exact_symbol", "exact_name", "exact_isin", "prefix",
        "typo", "substring", "multi_word", "symbol_spaces", "abbreviation",
    ]

    private struct Config {
        let tsvPath: String
        let queriesPath: String
        let iterations: Int
    }

    static func main() {
        let config = parseArgs()
        let queries = loadQueries(from: config.queriesPath)
        let instruments = loadCorpus(from: config.tsvPath)
        let matcher = FuzzyMatcher(caseSensitive: false, scheme: .path)

        let symbolCandidates = instruments.map(\.symbol)
        let nameCandidates = instruments.map(\.name)
        let isinCandidates = instruments.map(\.isin)

        func candidates(for field: String) -> [String] {
            switch field {
            case "symbol": symbolCandidates
            case "isin": isinCandidates
            default: nameCandidates
            }
        }

        print("Running \(queries.count) queries")
        print("")

        // Warmup
        do {
            var buffer = matcher.makeBuffer()
            for q in queries {
                let prepared = matcher.prepare(q.text)
                for candidate in candidates(for: q.field) {
                    _ = scoreCandidate(candidate, matcher: matcher, prepared: prepared, buffer: &buffer)
                }
            }
            print("Warmup complete")
        }

        var queryTimingsMs: [[Double]] = Array(repeating: [], count: queries.count)
        var queryMatchCounts: [Int] = Array(repeating: 0, count: queries.count)
        var iterationTotalsMs: [Double] = []

        print("")
        print("=== Benchmark: fltr(fuzzymatch) scoring \(queries.count) queries x \(instruments.count) candidates ===")
        print("")

        for iter in 0..<config.iterations {
            var buffer = matcher.makeBuffer()
            let iterStart = now()

            for (qi, q) in queries.enumerated() {
                let pool = candidates(for: q.field)
                let prepared = matcher.prepare(q.text)
                let qStart = now()
                let matchCount = scoreQuery(matcher: matcher, prepared: prepared, buffer: &buffer, candidates: pool)
                let qEnd = now()
                queryTimingsMs[qi].append(msFrom(qStart, to: qEnd))
                if iter == 0 {
                    queryMatchCounts[qi] = matchCount
                }
            }

            let iterMs = msFrom(iterStart, to: now())
            iterationTotalsMs.append(iterMs)
            print("Iteration \(iter + 1): \(String(format: "%.1f", iterMs))ms total")
        }

        printResults(
            queries: queries,
            queryTimingsMs: queryTimingsMs,
            queryMatchCounts: queryMatchCounts,
            iterationTotalsMs: iterationTotalsMs,
            iterations: config.iterations,
            candidateCount: instruments.count
        )
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

    private static func scoreQuery(
        matcher: FuzzyMatcher,
        prepared: PreparedPattern,
        buffer: inout MatcherScratch,
        candidates: [String]
    ) -> Int {
        var matchCount = 0
        var heap = MinHeap()

        for (ci, candidate) in candidates.enumerated() {
            guard let score = scoreCandidate(candidate, matcher: matcher, prepared: prepared, buffer: &buffer) else {
                continue
            }
            matchCount += 1

            let ranked = RankedCandidate(score: score, length: candidate.utf8.count, index: ci)
            if heap.count < topK {
                heap.push(ranked)
            } else if let currentMin = heap.min(), isBetter(ranked, than: currentMin) {
                heap.replaceMin(with: ranked)
            }
        }

        return matchCount
    }

    private static func isBetter(_ lhs: RankedCandidate, than rhs: RankedCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.length != rhs.length { return lhs.length < rhs.length }
        return lhs.index < rhs.index
    }

    private static func parseArgs() -> Config {
        let args = CommandLine.arguments
        let tsvPath = argValue(for: "--tsv", in: args) ?? "FuzzyMatch/Resources/instruments-export.tsv"
        let queriesPath = argValue(for: "--queries", in: args) ?? "FuzzyMatch/Resources/queries.tsv"
        let iterations = argValue(for: "--iterations", in: args).flatMap(Int.init) ?? 5
        return Config(tsvPath: tsvPath, queriesPath: queriesPath, iterations: max(1, iterations))
    }

    private static func argValue(for flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func loadQueries(from path: String) -> [Query] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        let content = String(decoding: data, as: UTF8.self)
        return content.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { return nil }
            return Query(text: String(cols[0]), field: String(cols[1]), category: String(cols[2]))
        }
    }

    private static func loadCorpus(from path: String) -> [Instrument] {
        print("Loading corpus from \(path)...", terminator: "")
        fflush(stdout)
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        let content = String(decoding: data, as: UTF8.self)
        print(" done (\(data.count) bytes)")
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
        print("Loaded \(instruments.count) instruments")
        return instruments
    }

    private static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private static func msFrom(_ start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000.0
    }

    private static func printResults(
        queries: [Query],
        queryTimingsMs: [[Double]],
        queryMatchCounts: [Int],
        iterationTotalsMs: [Double],
        iterations: Int,
        candidateCount: Int
    ) {
        print("")
        print("=== Results ===")
        print("")

        let medianTotal = iterationTotalsMs.sorted()[iterations / 2]
        let minTotal = iterationTotalsMs.min()!
        let maxTotal = iterationTotalsMs.max()!
        print("Total time for \(queries.count) queries (min/median/max): \(String(format: "%.1f", minTotal))ms / \(String(format: "%.1f", medianTotal))ms / \(String(format: "%.1f", maxTotal))ms")

        let totalScored = Double(candidateCount) * Double(queries.count)
        let throughput = totalScored / (medianTotal / 1000.0)
        print("Throughput (median): \(String(format: "%.0f", throughput / 1_000_000.0))M candidates/sec")
        print("Per-query average (median): \(String(format: "%.2f", medianTotal / Double(queries.count)))ms")
        print("")

        printCategorySummary(queries: queries, queryTimingsMs: queryTimingsMs, queryMatchCounts: queryMatchCounts, iterations: iterations)
        print("")
    }

    private static func printCategorySummary(
        queries: [Query],
        queryTimingsMs: [[Double]],
        queryMatchCounts: [Int],
        iterations: Int
    ) {
        let present = Set(queries.map(\.category))
        let categories = categoryOrder.filter { present.contains($0) }

        print("\(pad("Category", 22)) \(pad("Queries", 8, right: true)) \(pad("Med(ms)", 8, right: true)) \(pad("Min(ms)", 8, right: true)) \(pad("Matches", 8, right: true))")
        print(String(repeating: "-", count: 60))

        for cat in categories {
            let indices = queries.indices.filter { queries[$0].category == cat }
            guard !indices.isEmpty else { continue }

            let medians = indices.map { qi in queryTimingsMs[qi].sorted()[iterations / 2] }
            let totalMedian = medians.reduce(0, +)
            let totalMin = indices.map { qi in queryTimingsMs[qi].min()! }.reduce(0, +)
            let totalMatches = indices.map { queryMatchCounts[$0] }.reduce(0, +)

            print("\(pad(cat, 22)) \(pad("\(indices.count)", 8, right: true)) \(pad(fmtD(totalMedian, 2), 8, right: true)) \(pad(fmtD(totalMin, 2), 8, right: true)) \(pad("\(totalMatches)", 8, right: true))")
        }
    }

    private static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        if s.count >= width { return s }
        let padding = String(repeating: " ", count: width - s.count)
        return right ? padding + s : s + padding
    }

    private static func fmtD(_ v: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", v)
    }
}
