# Memory Profiling Guide

## Current Status

**Problem**: Initial load uses 234.8 MB but should theoretically use ~127 MB
**Gap**: ~108 MB unexplained

## Quick Profiling (Recommended)

### Option A: vmmap (fastest, shows memory regions)

```bash
./profile_vmmap.sh
```

This shows:
- Total memory by region type (MALLOC, Stack, etc.)
- Large allocations
- Saves detailed output to `/tmp/fltr_vmmap.txt`

**What to look for:**
- MALLOC_LARGE entries > 10 MB
- Unexpected large regions

### Option B: heap command (shows allocation details)

```bash
./profile_heap.sh
```

This shows:
- Live allocations sorted by size
- Counts of objects by type
- Saves output to `/tmp/fltr_heap.txt`

**What to look for:**
- Large Array allocations
- Unexpected String allocations
- Multiple copies of same data structure

## Detailed Profiling

### Instruments (GUI, most detailed)

```bash
./profile_instruments.sh
```

Follow the on-screen instructions. This gives:
- Timeline of allocations
- Stack traces for each allocation
- Persistent vs transient memory
- Ability to filter by type

**Key things to check:**
1. Sort by "Persistent Bytes" - what's using the most memory?
2. Filter for "Array" - are there large arrays we don't expect?
3. Filter for "String" - are Strings being allocated despite optimization?
4. Check "All Heap Allocations" for the biggest single allocations

## Manual Investigation

### 1. Check for String allocations

Add instrumentation to `Item.text()`:

```swift
// In Sources/FltrLib/Storage/Item.swift
func text(in buffer: TextBuffer) -> String {
    #if DEBUG
    print("⚠️ String allocation: item \(index), length \(length)")
    #endif
    return buffer.string(at: offset, length: length)
}
```

Rebuild and run - if you see warnings during initial load, Strings are being created unexpectedly.

### 2. Check ChunkList CoW

Add logging to ChunkList snapshot:

```swift
// In Sources/FltrLib/Storage/ChunkList.swift
func snapshot() -> ChunkList {
    #if DEBUG
    print("📸 Snapshot: frozen.count=\(frozen.count), capacity=\(frozen.capacity)")
    #endif
    return ChunkList(frozen: frozen, tailSnapshot: tail, totalCount: totalCount)
}
```

If you see many snapshots or large capacities, that might be the issue.

### 3. Measure Swift runtime baseline

Create a minimal program:

```swift
// minimal.swift
import Foundation
print("Starting...")
readLine()
```

```bash
swift minimal.swift &
PID=$!
sleep 1
ps -o rss= -p $PID
kill $PID
```

This shows Swift runtime + Foundation overhead (likely 15-30 MB).

## Expected Results

After profiling, you should find allocations in one of these categories:

| Category | Expected | If Larger | Action |
|----------|----------|-----------|--------|
| TextBuffer | ~93 MB | >120 MB | Array not shrunk, or multiple copies |
| ChunkStore | ~9 MB | >15 MB | Multiple snapshots kept, or not shrunk |
| Strings | 0 MB | >10 MB | Unexpected String allocations - find and eliminate |
| MatchedItems | 0 MB (no query) | >10 MB | ResultMerger holding old matches |
| Swift runtime | 15-30 MB | >50 MB | Normal for complex Swift programs |
| Unknown | 0 MB | >50 MB | Need deeper investigation |

## Next Steps After Profiling

Once you identify the culprit:

1. **If TextBuffer/ChunkStore**: Look at array growth and CoW behavior
2. **If String allocations**: Find where `.text()` is called and eliminate
3. **If multiple snapshots**: Reduce snapshot frequency or lifetime
4. **If Swift runtime**: This is hard to optimize, may need to accept it
5. **If unknown large allocation**: Use Instruments to get stack trace

## Reporting Results

When reporting findings, include:
- Total RSS from `ps` command
- Top 5 memory regions from vmmap
- Top 5 allocations from heap command
- Any suspicious patterns (many copies, unexpected types)
