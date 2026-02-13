#if MmapBuffer

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// mmap-backed append-only byte buffer.
///
/// Reserves a large virtual address range upfront (zero RSS cost on 64-bit);
/// pages fault in lazily at 4 KB granularity as bytes are written.
/// After EOF, ``releaseUnusedPages()`` calls ``madvise`` to return unused
/// pages to the OS, actually reducing reported RSS on macOS
/// (via ``MADV_FREE_REUSABLE``) and Linux (via ``MADV_DONTNEED``).
///
/// This bypasses macOS libmalloc's zone allocator entirely, eliminating the
/// ~120 MB of speculative ``MALLOC_LARGE`` pre-allocation that Swift's
/// ``Array<UInt8>`` incurs for large buffers.
final class MmapBuffer {
    private var base: UnsafeMutableRawPointer
    private var capacity: Int
    private(set) var count: Int = 0

    /// macOS-specific: marks pages as reclaimable AND reduces reported RSS.
    /// Unlike MADV_FREE, this actually reduces RSS without memory pressure.
    /// Value 7, used by WebKit/JSCore/jemalloc/mimalloc for 10+ years.
    #if canImport(Darwin)
    private static let MADV_FREE_REUSABLE_FLAG: Int32 = 7
    #endif

    /// Reserve *reserveSize* bytes of virtual address space.
    /// On 64-bit systems, this is essentially free — pages only become
    /// resident when written (lazy page fault, 4 KB at a time).
    init(reserveSize: Int = 512 * 1024 * 1024) {
        let pageSize = Int(getpagesize())
        // Round up to page boundary
        let aligned = (reserveSize + pageSize - 1) & ~(pageSize - 1)
        let ptr = mmap(
            nil,
            aligned,
            PROT_READ | PROT_WRITE,
            MAP_ANON | MAP_PRIVATE,
            -1,
            0
        )
        precondition(ptr != MAP_FAILED, "mmap failed to reserve \(aligned) bytes")
        self.base = ptr!
        self.capacity = aligned
    }

    deinit {
        munmap(base, capacity)
    }

    /// Append *length* bytes from *src* starting at *srcOffset*.
    /// Returns the (offset, length) of the written region within this buffer.
    @discardableResult
    func append(from src: UnsafeRawPointer, srcOffset: Int, length: Int) -> (offset: Int, length: Int) {
        let needed = count + length
        if needed > capacity {
            grow(to: needed)
        }
        memcpy(base + count, src + srcOffset, length)
        let writeOffset = count
        count += length
        return (writeOffset, length)
    }

    /// Append the UTF-8 bytes of *text*.
    /// Returns the (offset, length) of the written region.
    @discardableResult
    func append(_ text: String) -> (offset: Int, length: Int) {
        var t = text
        return t.withUTF8 { utf8 in
            let needed = count + utf8.count
            if needed > capacity {
                grow(to: needed)
            }
            memcpy(base + count, utf8.baseAddress!, utf8.count)
            let writeOffset = count
            count += utf8.count
            return (writeOffset, utf8.count)
        }
    }

    /// Read access to the buffer contents as ``UnsafeBufferPointer<UInt8>``.
    var bufferPointer: UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: UInt8.self),
            count: count
        )
    }

    /// Release pages beyond *count* back to the OS.
    ///
    /// On macOS, uses ``MADV_FREE_REUSABLE`` which actually reduces reported
    /// RSS (unlike ``MADV_FREE``).  On Linux, uses ``MADV_DONTNEED`` which
    /// immediately zeroes pages and reduces RSS.
    ///
    /// Call once after the last append (stdin EOF).
    func releaseUnusedPages() {
        let pageSize = Int(getpagesize())
        let usedPages = (count + pageSize - 1) & ~(pageSize - 1)
        let unusedLen = capacity - usedPages
        guard unusedLen > 0 else { return }

        let unusedStart = base + usedPages
        #if canImport(Darwin)
        _ = madvise(unusedStart, unusedLen, MmapBuffer.MADV_FREE_REUSABLE_FLAG)
        #else
        // Linux: MADV_DONTNEED immediately frees pages and reduces RSS.
        _ = madvise(unusedStart, unusedLen, MADV_DONTNEED)
        #endif
    }

    /// Grow the mapped region to accommodate at least *needed* bytes.
    /// Allocates a new region, copies existing data, and unmaps the old one.
    private func grow(to needed: Int) {
        let pageSize = Int(getpagesize())
        let newCapacity = max(
            (needed + pageSize - 1) & ~(pageSize - 1),
            capacity * 2
        )
        let newPtr = mmap(
            nil,
            newCapacity,
            PROT_READ | PROT_WRITE,
            MAP_ANON | MAP_PRIVATE,
            -1,
            0
        )
        precondition(newPtr != MAP_FAILED, "mmap failed to grow to \(newCapacity) bytes")
        memcpy(newPtr!, base, count)
        munmap(base, capacity)
        base = newPtr!
        capacity = newCapacity
    }
}

#endif // MmapBuffer
