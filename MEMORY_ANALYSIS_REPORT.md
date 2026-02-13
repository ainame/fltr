# fltr Memory Efficiency Analysis

## Test Configuration
- **Input**: find.txt
- **Lines**: 827,707
- **Raw text size**: 97.8 MB
- **fltr memory**: ~243 MB
- **fzf memory**: ~148 MB
- **Difference**: 95 MB (64% more)

## Memory Breakdown

### 1. Base Storage: ~102 MB ✅
- **TextBuffer**: 93 MB (contiguous `[UInt8]` for all text)
- **ChunkStore**: 9 MB (827,707 items × 12 bytes per Item, organized in chunks)
- **Status**: Optimized, matches fzf's approach

### 2. MatchedItem Arrays: ~30-60 MB ⚠️
**Current implementation:**
```swift
struct MatchedItem {           // Total: ~112 bytes each
    let item: Item             // 12 bytes
    let matchResult: MatchResult // 16 bytes (stack) + ~72 bytes (heap)
    let points: UInt64         // 8 bytes
}

struct MatchResult {
    let score: Int             // 8 bytes
    let positions: [Int]       // Array: 32 bytes overhead + 8 bytes × count
}
```

**Problem**: ResultMerger stores partitions as `[[MatchedItem]]`:
- Each MatchedItem: **112 bytes** (vs 12 bytes for Item)
- 50% selectivity (413k matches): 413,000 × 112 = **46 MB**
- 90% selectivity (745k matches): 745,000 × 112 = **83 MB**

**This is the PRIMARY memory hotspot.**

### 3. Array Growth Overhead: ~20-30 MB ⚠️
- Swift arrays grow by 1.5-2× capacity, leaving ~30% headroom
- TextBuffer: potentially +27 MB if not shrunk
- ChunkStore: potentially +2 MB if not shrunk
- Partition arrays: +10-15 MB (each partition array has growth overhead)

**Status**: `shrinkToFit()` is called for TextBuffer and ChunkStore, but **NOT** for partition arrays in ResultMerger.

### 4. ChunkCache: ~3-12 MB ⚠️
- Max 20 items per chunk, 8,278 chunks
- If fully populated: 8,278 × 20 × 112 bytes = **18 MB**
- Realistic (30% cache hit): ~5 MB

### 5. Swift Runtime & Misc: ~15-20 MB
- Swift runtime: 10-15 MB
- UI buffers: 1-2 MB
- Actor overhead: <1 MB
- Matrix buffers (@TaskLocal, 10 workers): ~1.4 MB

**Status**: Expected baseline, unavoidable.

---

## Root Cause Analysis

### Why is fltr using 95 MB more than fzf?

1. **MatchedItem storage** (+30-50 MB):
   - Swift: 112 bytes per MatchedItem
   - Go (fzf): likely ~32-48 bytes (more compact struct + slice overhead)
   - For 400k matches: 32-44 MB difference

2. **Array growth overhead** (+20-30 MB):
   - Partition arrays not shrunk
   - Multiple allocations for ChunkCache entries

3. **Swift runtime** (+10-15 MB):
   - Swift runtime is heavier than Go runtime

4. **Positions array allocation** (+10-20 MB):
   - Each MatchResult has a heap-allocated `[Int]` for positions
   - Even with 5 positions: 32 + 40 = 72 bytes overhead per item
   - fzf likely uses a more compact representation

**Total: ~70-115 MB difference** ✓ (matches observed 95 MB)

---

## Optimization Opportunities

### 🔴 HIGH IMPACT (30-50 MB savings)

#### 1. Compact MatchedItem Representation
**Problem**: `positions: [Int]` allocates a heap array (72 bytes for 5 positions)

**Solutions**:

**Option A**: Inline positions for common case (≤ 8 positions)
```swift
struct MatchResult {
    let score: Int
    let positionsInline: (UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16)  // 16 bytes
    let count: UInt8   // 1 byte
    // Fallback: positions: [Int]? only when > 8 positions
}
```
- Saves: ~60 bytes per MatchedItem (from 112 → 52 bytes)
- For 400k items: **24 MB savings**

**Option B**: Pack positions as UInt16 offsets (max 65,535 byte lines)
```swift
struct MatchResult {
    let score: Int16           // 2 bytes (scores rarely exceed 32k)
    let positions: [UInt16]    // 32 + 2*count bytes
}
```
- Saves: ~40 bytes per MatchedItem (from 112 → 72 bytes)
- For 400k items: **16 MB savings**

**Option C** (most aggressive): Store positions lazily, recompute on demand
```swift
struct MatchedItem {
    let item: Item            // 12 bytes
    let score: Int16          // 2 bytes
    let points: UInt64        // 8 bytes
    // positions computed on-demand when rendering (cold path)
}
```
- Saves: ~90 bytes per MatchedItem (from 112 → 22 bytes)
- For 400k items: **36 MB savings**
- **Trade-off**: Re-compute positions when rendering (acceptable since rendering is <50 items)

#### 2. Shrink Partition Arrays After Sorting
**Problem**: Each partition array has ~30% growth overhead

**Solution**:
```swift
// In MatchingEngine.swift, after sorting each partition:
group.addTask {
    var partition = // ... match items ...
    partition.sort { rankLessThan($0, $1) }
    partition.shrink(toFit: partition.count)  // NEW: shrink before return
    return partition
}
```
- Saves: ~10-15 MB

### 🟡 MEDIUM IMPACT (5-15 MB savings)

#### 3. Limit ChunkCache Size
**Current**: Unbounded growth (can reach 18 MB)

**Solution**: Add LRU eviction or max cache size
```swift
final class ChunkCache {
    static let maxCacheSize = 5_000_000  // ~5 MB limit
    private var totalCachedItems = 0

    func add(...) {
        guard totalCachedItems < Self.maxCacheSize else {
            evictOldest()  // or return without caching
        }
        // ...
    }
}
```
- Saves: ~5-10 MB (prevents unbounded growth)

#### 4. Reduce Matrix Buffer Retention
**Current**: @TaskLocal buffers persist for task lifetime

**Solution**: Clear buffers after large allocations
```swift
// After processing a very long line:
if textLen > 1000 {
    // Release the large buffer so next task doesn't inherit it
    matrixBuffer = nil
}
```
- Saves: ~1-2 MB (prevents rare long-line buffers from persisting)

### 🟢 LOW IMPACT (<5 MB savings)

#### 5. Use Int32 for scores
**Current**: `score: Int` (8 bytes)
**Proposed**: `score: Int32` (4 bytes)
- Scores rarely exceed 2 billion
- Saves: 4 bytes per MatchedItem → 1.6 MB for 400k items

#### 6. Pool MatchResult Instances
Reuse MatchResult(score: 0, positions: []) for empty queries
- Saves: ~1-2 MB

---

## Recommendations (Priority Order)

### Phase 1: Quick Wins (1-2 hours, 15-25 MB savings)
1. ✅ Shrink partition arrays after sorting (10-15 MB)
2. ✅ Use Int16 for scores (1-2 MB)
3. ✅ Add ChunkCache size limit (5-10 MB)

### Phase 2: Structural Changes (4-6 hours, 25-40 MB savings)
4. ✅ Pack positions as [UInt16] instead of [Int] (15-20 MB)
5. ✅ Inline positions for ≤8 positions (10-15 MB)

### Phase 3: Aggressive Optimizations (8-12 hours, 30-50 MB savings)
6. ⚠️ Lazy position computation (36 MB, but adds complexity)
7. ⚠️ Custom allocator for MatchedItem arrays (10-20 MB, high complexity)

---

## Expected Results

| Optimization | Effort | Savings | Risk |
|--------------|--------|---------|------|
| Shrink partition arrays | Low | 10-15 MB | Low |
| UInt16 positions | Medium | 15-20 MB | Low |
| Inline positions (≤8) | Medium | 10-15 MB | Medium |
| ChunkCache limit | Low | 5-10 MB | Low |
| Int16 scores | Low | 1-2 MB | Low |
| **TOTAL (Phase 1+2)** | **1 day** | **40-60 MB** | **Low** |

**Target**: Reduce fltr memory from 243 MB → **180-200 MB** (20-25% reduction)
**Still more than fzf** (148 MB), but acceptable given Swift runtime overhead.

---

## Verification Plan

1. **Baseline measurement** (current state):
   ```bash
   cat find.txt | fltr &
   PID=$!; sleep 2; ps -o rss= -p $PID
   ```

2. **After each optimization**:
   - Rebuild: `swift build -c release`
   - Measure: Same as baseline
   - Compare: Expect incremental reduction

3. **Benchmark matching performance**:
   ```bash
   .build/release/matcher-benchmark --count 500000 --mode all --runs 5
   ```
   - Ensure no performance regression

4. **Integration test**:
   ```bash
   cat find.txt | .build/release/fltr --query "test"
   # Verify UI still works, results correct
   ```

---

## Conclusion

fltr uses **64% more memory than fzf** (243 MB vs 148 MB) primarily due to:
1. **MatchedItem bloat**: 112 bytes vs fzf's compact representation
2. **Array growth overhead**: Partition arrays not shrunk
3. **Swift runtime**: Inherent 10-15 MB baseline

**Recommended first steps**:
1. Shrink partition arrays → immediate 10-15 MB savings, zero risk
2. Switch to UInt16 positions → 15-20 MB savings, low risk
3. Add ChunkCache limit → prevent unbounded growth

These changes should reduce memory to **~180-200 MB** while maintaining performance.
