# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**bokeh** is a cross-platform fuzzy finder CLI tool written in Swift 6.2. The name comes from the Japanese word meaning "fuzzy." It's inspired by fzf (Go) and skim (Rust), providing interactive real-time fuzzy filtering with multi-select support and preview windows.

## Build & Test Commands

```bash
# Build
swift build                    # Debug build
swift build -c release         # Release build (optimized)

# Test
swift test

# Run
.build/release/bokeh
ls | .build/release/bokeh      # Pipe data to filter

# Interactive testing
./test_bokeh.sh
```

## Architecture

The project has two main targets:

```
bokeh (Executable)
├── Matcher/      - FuzzyMatchV2 algorithm (modified Smith-Waterman)
├── Storage/      - ItemCache (actor), ChunkList with InlineArray
├── Engine/       - MatchingEngine (parallel matching via TaskGroup)
├── Reader/       - StdinReader (streaming, non-blocking)
└── UI/           - UIController (event loop), UIState (view model)
    │
    └── depends on ──▶ TUI (Library)
                      ├── RawTerminal    - Raw mode, /dev/tty access
                      ├── KeyboardInput  - Key event parsing
                      ├── TextRenderer   - Unicode display width
                      └── Screen         - Virtual buffer
```

### Key Components

- **FuzzyMatcher** (`Sources/bokeh/Matcher/`): Fuzzy matching with space-separated AND queries. Uses FuzzyMatchV2 with scoring bonuses for word boundaries, CamelCase, and consecutive matches.

- **ItemCache** (`Sources/bokeh/Storage/ItemCache.swift`): Actor-based thread-safe storage using chunk-based architecture (100 items per chunk) with InlineArray for zero-heap allocation.

- **MatchingEngine** (`Sources/bokeh/Engine/MatchingEngine.swift`): Parallel matching using TaskGroup. Smart threshold: only parallelizes for >1000 items.

- **UIController** (`Sources/bokeh/UI/UIController.swift`): Main event loop with 100ms refresh interval for streaming data.

- **TUI library** (`Sources/TUI/`): Reusable terminal UI foundation that can be used independently.

## Concurrency Model

- Swift 6 strict concurrency with actors
- **Actors**: ItemCache, RawTerminal, UIController
- **TaskGroup**: Parallel matching across CPU cores
- **TaskLocal**: Per-task matrix buffer storage for algorithm optimization

## Performance Optimizations

Key optimizations implemented:
- Static delimiter set in CharClass (eliminates allocations per search)
- Matrix buffer reuse via TaskLocal storage
- Zero-copy iteration in ChunkList
- Incremental filtering (searches previous results when query extends)
- `@inlinable` on hot path functions

## Platform Support

- macOS 14+ (Sonoma)
- Linux (via Swift 6.2)
- Requires ANSI escape sequence support and `/dev/tty` access
