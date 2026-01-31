import TUI

actor TestTerminal: Terminal {
    private var inputQueue: [UInt8] = []
    private(set) var output: String = ""
    private(set) var enteredRawMode = false
    private var size: (rows: Int, cols: Int)

    init(rows: Int = 24, cols: Int = 80) {
        self.size = (rows, cols)
    }

    func enterRawMode() {
        enteredRawMode = true
    }

    func exitRawMode() {
        enteredRawMode = false
    }

    func getSize() throws -> (rows: Int, cols: Int) {
        size
    }

    func write(_ string: String) {
        output += string
    }

    func flush() {}

    func readByte() -> UInt8? {
        guard !inputQueue.isEmpty else { return nil }
        return inputQueue.removeFirst()
    }

    func enqueue(bytes: [UInt8]) {
        inputQueue.append(contentsOf: bytes)
    }

    func setSize(rows: Int, cols: Int) {
        size = (rows, cols)
    }

    func clearOutput() {
        output.removeAll(keepingCapacity: true)
    }
}
