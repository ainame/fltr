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
├── Engine/       - MatchingEngine (parallel matching via TaskGroup)
├── Reader/       - StdinReader (streaming, non-blocking)
└── UI/           - Modular UI components
    ├── UIController.swift     - Event loop orchestrator (actor, ~340 lines)
    ├── InputHandler.swift     - Keyboard/mouse parsing & routing (~200 lines)
    ├── UIRenderer.swift       - UI element rendering (~220 lines)
    ├── PreviewManager.swift   - Preview command execution & rendering (~210 lines)
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

- **ItemCache** (`Sources/fltr/Storage/ItemCache.swift`): Actor-based thread-safe storage using chunk-based architecture (100 items per chunk) with InlineArray for zero-heap allocation.

- **MatchingEngine** (`Sources/fltr/Engine/MatchingEngine.swift`): Parallel matching using TaskGroup. Smart threshold: only parallelizes for >1000 items.

- **UIController** (`Sources/fltr/UI/UIController.swift`): Main event loop orchestrator with 100ms refresh interval for streaming data. Coordinates between InputHandler, UIRenderer, and PreviewManager components.

- **InputHandler** (`Sources/fltr/UI/InputHandler.swift`): Parses keyboard/mouse events (escape sequences, arrow keys, mouse scrolling) and routes them to appropriate state updates.

- **UIRenderer** (`Sources/fltr/UI/UIRenderer.swift`): Renders UI elements (input field with cursor, item list, status bar, borders) using single-buffer strategy for performance.

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
- Static delimiter set in CharClass (eliminates allocations per search)
- Matrix buffer reuse via TaskLocal storage
- Zero-copy iteration in ChunkList
- Incremental filtering (searches previous results when query extends)
- `@inlinable` on hot path functions

## Platform Support

- macOS 14+ (Sonoma)
- Linux (via Swift 6.2 Static Linux SDK with musl)
- Requires ANSI escape sequence support and `/dev/tty` access
