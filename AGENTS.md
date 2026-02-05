# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**fltr** (short for "filter") is a cross-platform fuzzy finder CLI tool written in Swift 6.2. It's inspired by fzf (Go) and skim (Rust), providing interactive real-time fuzzy filtering with multi-select support and preview windows.

## Build & Test Commands

```bash
# Build
swift build                    # Debug build
swift build -c release         # Release build (optimized)
swift build --swift-sdk swift-6.2-RELEASE_static-linux-0.0.1  # Linux static build

# Test
swift test

# Run
.build/release/fltr
ls | .build/release/fltr       # Pipe data to filter
```

## Architecture

The project has two main targets:

```
fltr (Executable)
├── Matcher/      - FuzzyMatchV2 algorithm (modified Smith-Waterman)
├── Storage/      - ItemCache (actor), ChunkList with InlineArray
├── Engine/       - MatchingEngine + ResultMerger (parallel matching via TaskGroup)
├── Reader/       - StdinReader (streaming, non-blocking)
└── UI/           - Modular UI components
    ├── UIController.swift     - Event loop orchestrator (actor, ~420 lines)
    ├── InputHandler.swift     - Keyboard/mouse parsing & routing (~200 lines)
    ├── UIRenderer.swift       - UI element rendering (~220 lines)
    ├── PreviewManager.swift   - Preview command execution & rendering (~210 lines)
    ├── PreviewState.swift     - Preview view state + render forwarding
    ├── MergerCache.swift      - Single-entry merger-level result cache
    └── UIState.swift          - View model (state management)
    │
    └── depends on ──▶ TUI (Library)
                      ├── RawTerminal    - Raw mode, /dev/tty access
                      ├── KeyboardInput  - Key event parsing (Emacs bindings)
                      ├── TextRenderer   - Unicode display width
                      └── Screen         - Virtual buffer

FltrCSystem (C Shim Library)
└── Cross-platform POSIX APIs for terminal control
```

### Key Components

- **FuzzyMatcher** (`Sources/fltr/Matcher/`): Fuzzy matching with space-separated AND queries. Uses FuzzyMatchV2 with scoring bonuses for word boundaries, CamelCase, and consecutive matches.

- **ItemCache** (`Sources/fltr/Storage/ItemCache.swift`): Actor-based thread-safe storage.  Owns the single ``TextBuffer`` (contiguous ``[UInt8]`` for all input text) and a ``ChunkStore``.  Items are registered via ``registerItem(offset:length:)`` — only two ``UInt32`` values cross the actor boundary per line.  ``buffer`` is ``nonisolated let`` (safe: ``TextBuffer`` is ``@unchecked Sendable`` and never reassigned) so the hot path and UI can capture it without actor hops.  ``sealAndShrink()`` is called once after stdin EOF to reclaim Array growth headroom in both the TextBuffer and the ChunkStore.

- **ChunkStore / ChunkList** (`Sources/fltr/Storage/ChunkList.swift`): Items are grouped into 100-item ``Chunk`` structs (``InlineArray<100>``, ~2.4 KB each).  The live store keeps a ``frozen`` array of sealed (full) chunks and a mutable ``tail``.  A snapshot (``ChunkList``) captures ``frozen`` by value (Swift CoW — zero physical copy at snapshot time) and copies only the ``tail`` (~2.4 KB).  CoW materialises a copy only when the *next* chunk seals — once per 100 items rather than once per item — so concurrent snapshots during streaming share the same backing storage and add negligible RSS.

- **MatchingEngine** (`Sources/fltr/Engine/MatchingEngine.swift`): Parallel matching using TaskGroup. Smart threshold: only parallelizes for >1000 items. Each partition sorts locally; results are returned as a `ResultMerger`.

- **ResultMerger** (`Sources/fltr/Engine/ResultMerger.swift`): Lazy k-way merge of per-partition sorted results (mirrors fzf's Merger). `count` is O(1); `get`/`slice` materialise in global rank order on demand — the terminal only pays for the visible window, not a full O(n log n) sort.

- **UIController** (`Sources/fltr/UI/UIController.swift`): Main event loop orchestrator (actor) with 100ms refresh interval for streaming data. Owns the debounce task, fetchItemsTask, and the single render path. Holds `MergerCache` and `PreviewState` as stored-property structs — all access stays actor-isolated with zero extra hops. Materialises the visible item window from the ResultMerger before each render pass.

- **MergerCache** (`Sources/fltr/UI/MergerCache.swift`): Single-entry `(pattern, itemCount) → ResultMerger` cache extracted from UIController. `lookup` / `store` / `invalidate` are the full surface. Low-selectivity results (> 100 k) are deliberately not cached.

- **PreviewState** (`Sources/fltr/UI/PreviewState.swift`): All preview view state in one struct: cached output, scroll offset, visibility toggles, hit-test bounds, and the `PreviewManager` reference. Owns the two render helpers (`renderSplit`, `renderFloating`) that forward to PreviewManager. Task lifecycle (`currentPreviewTask`) stays on UIController.

- **InputHandler** (`Sources/fltr/UI/InputHandler.swift`): Parses keyboard/mouse events (escape sequences, arrow keys, mouse scrolling) and routes them to appropriate state updates.

- **UIRenderer** (`Sources/fltr/UI/UIRenderer.swift`): Renders UI elements (input field with cursor, item list, status bar, borders) using single-buffer strategy for performance. Receives the pre-sliced visible item window as a parameter (materialised by UIController).

- **PreviewManager** (`Sources/fltr/UI/PreviewManager.swift`): Executes preview commands with timeout and renders both split-screen (fzf style) and floating window previews.

- **TUI library** (`Sources/TUI/`): Reusable terminal UI foundation that can be used independently.

- **FltrCSystem** (`Sources/FltrCSystem/`): C shims for cross-platform POSIX APIs (ioctl, termios). Required for Linux musl compatibility.

## UI Architecture

The UI is split into focused components with clear responsibilities:

```
Raw Input → UIController.handleKey()
          ↓
          InputHandler.parseEscapeSequence() → Key
          ↓
          InputHandler.handleKeyEvent() → InputAction + mutate UIState
          ↓
          UIController handles action:
          - scheduleMatchUpdate: trigger debounced matching
          - updatePreview: execute preview command
          - updatePreviewScroll: adjust preview scroll offset
          - togglePreview: show/hide preview window
          ↓
          UIController.render()
          ↓
          UIRenderer.assembleFrame() → buffer string
          ↓
          PreviewManager.renderPreview() → preview buffer (if enabled)
          ↓
          terminal.write(buffer)
```

### UI Features

- **Input field with cursor**: Visual block cursor showing current position
- **Emacs-like key bindings**:
  - Ctrl-A: Beginning of line
  - Ctrl-E: End of line
  - Ctrl-F / Ctrl-B: Forward/backward character
  - Ctrl-K: Kill to end of line
  - Ctrl-U: Clear line
- **Border below input**: Thin horizontal line separating input from results
- **Preview windows**: Split-screen (fzf style) and floating overlay modes
- **Mouse support**: Scroll events for both item list and preview windows

## Concurrency Model

- Swift 6 strict concurrency with actors
- **Actors**: ItemCache, RawTerminal, UIController
- **TaskGroup**: Parallel matching across CPU cores
- **TaskLocal**: Per-task matrix buffer storage for algorithm optimization

## Performance Optimizations

Key optimizations implemented:
- **TextBuffer**: all input text lives in a single contiguous ``[UInt8]``; each ``Item`` is an ``(offset, length)`` window — no per-line ``String`` heap allocation.  The ``TextBuffer`` reference is *not* stored inside ``Item``; it is threaded explicitly through the call graph so that every ``Item`` is exactly 12 bytes.
- **12-byte Item** (`Int32 index` + `UInt32 offset` + `UInt32 length`): the shared ``TextBuffer`` reference was removed from ``Item`` (all Items pointed to the same instance).  ``index`` is ``Int32`` via the ``Item.Index`` typealias.  The hot-path matcher receives the buffer as ``UnsafeBufferPointer<UInt8>`` inside ``withBytes`` scopes; ``buildPoints`` walks raw bytes with zero ``String`` allocation.  Cold paths (render, output, preview) receive a ``TextBuffer`` parameter.  The chunkBacked zero-alloc path synthesises ``MatchedItem`` with pre-computed ``points`` — no buffer access at all.
- **shrinkToFit after EOF**: ``TextBuffer.shrinkToFit()`` and ``ChunkStore.shrinkToFit()`` each reallocate their backing ``[UInt8]`` / ``[Chunk]`` at exact count, reclaiming the ~30 % headroom left by Array's doubling growth strategy.  Both are invoked once via ``ItemCache.sealAndShrink()``, called by ``StdinReader`` immediately after the read loop completes.
- **fread-based StdinReader**: 64 KB read buffer, byte-scan for newlines, whitespace trimmed without Foundation; bytes appended directly into TextBuffer off-actor
- **ChunkStore frozen/tail split**: sealed chunks are CoW-shared across snapshots; the tail (~2.4 KB) is the only per-snapshot copy, so concurrent streaming snapshots add negligible RSS
- Static delimiter set in CharClass (eliminates allocations per search)
- Matrix buffer reuse via TaskLocal storage
- Incremental filtering: when the query extends the previous one, searches within the previous match set (lossless — results are never capped)
- Lazy materialisation via ResultMerger: only the visible ~20–50 rows are sorted globally; per-partition sort is O(k log k) where k = partition size
- `@inlinable` on hot path functions

### Benchmarking matching changes

When changing matcher/engine code, run the release benchmark with at least 500k items and compare medians:

```bash
swift build -c release --target matcher-benchmark
.build/release/matcher-benchmark --count 500000 --mode all --runs 5 --warmup 2
```

Recommended workflow for agents (before/after comparison):

1) Run baseline and save output:
```bash
.build/release/matcher-benchmark --count 500000 --mode all --runs 5 --warmup 2 --seed 1337 > /tmp/fltr-bench.before.txt
```

2) Apply changes, rebuild, rerun with the same arguments:
```bash
swift build -c release --target matcher-benchmark
.build/release/matcher-benchmark --count 500000 --mode all --runs 5 --warmup 2 --seed 1337 > /tmp/fltr-bench.after.txt
```

3) Compare the median/avg lines (engine + matcher) and report deltas:
```bash
diff -u /tmp/fltr-bench.before.txt /tmp/fltr-bench.after.txt
```

Notes:
- Keep the same `--count`, `--seed`, `--mode`, and machine when comparing.
- Prefer `--mode engine` if only the parallel matcher changed.

### Makefile helpers

Convenience targets for profiling and benchmarks:

```bash
# Record a Time Profiler trace (open later in Instruments)
make profile INPUT=./input.txt ARGS="--query foo"

# Run matcher benchmark with defaults (override as needed)
make benchmark
```

## Platform Support

- macOS 14+ (Sonoma)
- Linux (via Swift 6.2 Static Linux SDK with musl)
- Requires ANSI escape sequence support and `/dev/tty` access
