public protocol Terminal: Actor {
    func enterRawMode() throws
    func exitRawMode()
    func getSize() throws -> (rows: Int, cols: Int)
    func write(_ string: String)
    func flush()
    func readByte() -> UInt8?
}
