# fltr

A cross-platform fuzzy finder CLI tool written in Swift 6.2.

**fltr** (short for "filter") is inspired by [fzf](https://github.com/junegunn/fzf) (Go) and [skim](https://github.com/lotabout/skim) (Rust), but leverages Swift's modern concurrency features and ecosystem.

## Features

- **Interactive fuzzy search** with real-time filtering
- **FuzzyMatchV2 algorithm** (modified Smith-Waterman with scoring bonuses)
- **Multi-select mode** (`-m`) with Tab to toggle selections
- **Preview windows** - Split-screen or floating overlay styles
- **Streaming stdin** - UI starts immediately while still reading input
- **Parallel matching** - Distributes work across CPU cores for large datasets
- **Incremental filtering** - Searches within previous results when query extends
- **Unicode support** - CJK characters, emojis, grapheme clusters
- **Whitespace as AND** - "swift util" matches items containing both tokens
- **Case-insensitive** by default (with `--case-sensitive` option)
- **Emacs-like key bindings** - Ctrl-A, Ctrl-E, Ctrl-F, Ctrl-B, Ctrl-K for cursor movement

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd fltr

# Build
swift build -c release

# Install (optional)
cp .build/release/fltr /usr/local/bin/
```

## Usage

### Basic Usage

```bash
# Pipe data to fltr
ls | fltr

# Find files
find . -type f | fltr

# Filter command history
history | fltr

# Works great with massive datasets (streams in background)
find / -type f 2>/dev/null | fltr
# UI starts immediately, even while find is still running!
```

**Note:** fltr streams stdin in the background, so the UI appears immediately even for huge datasets. The status bar shows `[loading...]` while input is still being read. This means you can start typing and filtering even before all items have loaded!

### Command-Line Options

```bash
fltr --help

USAGE: fltr [--height <height>] [--multi] [--case-sensitive] [--preview <preview>] [--preview-float <preview-float>]

OPTIONS:
  -h, --height <height>   Maximum display height (number of result lines)
                          Omit to use full terminal height (default)
  -m, --multi             Enable multi-select mode
  --case-sensitive        Enable case-sensitive matching
  --preview <command>     Preview command (split-screen style, like fzf)
                          Use {} as placeholder for item text
  --preview-float <command> Preview command (floating window overlay)
                          Use {} as placeholder for item text
  --help                  Show help information
```

### Key Bindings

| Key | Action |
|-----|--------|
| Type characters | Filter items with fuzzy matching |
| `Up` / `Down` / `Ctrl-P` / `Ctrl-N` | Navigate through results (scrolls automatically) |
| `Left` / `Right` / `Ctrl-B` / `Ctrl-F` | Move cursor in input field |
| `Ctrl-A` | Move cursor to beginning of input |
| `Ctrl-E` | Move cursor to end of input |
| `Ctrl-K` | Delete from cursor to end of input |
| `Enter` | Select current item and exit |
| `Tab` | Toggle multi-select on current item (requires `-m`) |
| `Esc` / `Ctrl-C` | Exit without selection |
| `Ctrl-U` | Clear query |
| `Ctrl-O` | Toggle preview window on/off |
| `Backspace` | Delete character before cursor |

**Note:** Results scroll automatically when you navigate beyond the visible area. The status bar shows a scroll percentage indicator `[%]` when there are more items than fit on screen.

### Examples

```bash
# Basic file selection (uses full terminal height by default)
echo -e "apple\nbanana\ncherry\napricot\navocado" | fltr

# Multi-select mode
ls -la | fltr --multi

# Limit display height to 15 lines
find . -name "*.swift" | fltr --height 15

# Case-sensitive matching
cat words.txt | fltr --case-sensitive

# Full terminal height is great for large datasets
find . -type f | fltr  # Shows as many results as fit on your screen

# Preview file contents (split-screen, fzf style)
find . -name "*.swift" | fltr --preview 'cat {}'
# Press Ctrl-O to toggle preview on/off

# Preview with syntax highlighting (split-screen)
find . -type f | fltr --preview 'bat --color=always --style=numbers {}'

# Floating preview window overlay
find . -type f | fltr --preview-float 'head -30 {}'
# Press Ctrl-O to toggle floating window
```

### Preview Window

fltr supports **two preview styles**:

#### 1. Split-Screen Preview (`--preview`) - fzf style

The default preview mode shows a split-screen layout (50/50) with a vertical separator:

```bash
# Split-screen preview (always visible)
find . -type f | fltr --preview 'cat {}'

# With syntax highlighting
find . -type f | fltr --preview 'bat --color=always --style=numbers {}'
```

**Split-screen features:**
- **50/50 layout** - List on left, preview on right
- **Orange vertical separator** - Clear visual boundary
- **Always visible** - Preview updates as you navigate
- **Auto-updates** - Preview refreshes when you select different items
- **Toggle with Ctrl-O** - Hide/show preview pane

**Navigation in split-screen mode:**
- Use arrow keys to navigate the item list
- Preview automatically updates to show the selected item
- Press `Ctrl-O` to toggle preview pane on/off

#### 2. Floating Window Preview (`--preview-float`)

An overlay-style preview window that appears on top of the list:

```bash
# Floating window preview
find . -type f | fltr --preview-float 'head -30 {}'
```

**Floating window features:**
- **Clean single-line borders** (┌─┐ │ └─┘) in Swift orange
- **Left-aligned title** showing the selected filename
- **80% of screen size**, centered overlay
- **Toggle with Ctrl-O** - show/hide without exiting
- **Auto-updates** as you navigate through items

**Preview controls:**
- `Ctrl-O` - Toggle floating window on/off
- `Up` / `Down` - Navigate through items (preview updates automatically)

#### Command Placeholder

Both preview modes use `{}` as a placeholder for the selected item text. You can use any shell command:
- `cat {}` - Show file contents
- `head -50 {}` - First 50 lines
- `bat --color=always {}` - Syntax highlighted content
- `file {}` - File type info
- `git log -- {}` - Git history for file

## Architecture

fltr is built with a modular architecture, separating reusable TUI components from application logic:

### Targets

```
┌─────────────────────────────────────────────┐
│                  fltr                       │  ← Executable
│                                             │
│  Fuzzy Finder Implementation:               │
│  - Matcher/     (fuzzy matching algorithm)  │
│  - Storage/     (item cache, chunks)        │
│  - Engine/      (parallel matching)         │
│  - Reader/      (stdin streaming)           │
│  - UI/          (UIController, UIState)     │
└──────────────────┬──────────────────────────┘
                   │ depends on
                   ↓
┌─────────────────────────────────────────────┐
│                TUI                          │  ← Library
│                                             │
│  Reusable Terminal UI Foundation:           │
│  - RawTerminal     (raw mode, I/O, cursor)  │
│  - KeyboardInput   (key parsing)            │
│  - TextRenderer    (Unicode, ANSI)          │
│  - Screen          (virtual buffer)         │
└─────────────────────────────────────────────┘
```

### Component Structure

```
┌─────────────┐
│   stdin     │ ← Input source
└──────┬──────┘
       │
┌──────▼──────────┐
│  StdinReader    │ ← Reads lines into cache
│  (Actor)        │
└──────┬──────────┘
       │
┌──────▼──────────┐
│   ItemCache     │ ← Chunk-based storage
│   (Actor)       │
└──────┬──────────┘
       │
┌──────▼──────────┐
│ FuzzyMatcher    │ ← FuzzyMatchV2 algorithm
└──────┬──────────┘
       │
┌──────▼──────────┐
│  UIController   │ ← Event loop, rendering
│   (Actor)       │
└──────┬──────────┘
       │
┌──────▼──────────┐
│  RawTerminal    │ ← Terminal control (TUI)
│   (Actor)       │
└──────┬──────────┘
       │
┌──────▼──────────┐
│    stdout       │ ← Selected items output
└─────────────────┘
```

### TUI Library

TUI is a reusable terminal UI library that can be used independently:

**RawTerminal** - Low-level terminal control
- Raw mode activation/deactivation
- Alternate screen buffer
- Cursor positioning and visibility
- Non-blocking byte reading
- Terminal size detection

**KeyboardInput** - Keyboard event parsing
- ASCII character input
- Control keys (Ctrl-C, Ctrl-D, etc.)
- Arrow keys and escape sequences
- Special keys (Tab, Enter, Backspace)
- Emacs-like bindings (Ctrl-A, Ctrl-E, Ctrl-F, Ctrl-B, Ctrl-K)

**TextRenderer** - Unicode-aware text rendering
- Display width calculation (CJK, emoji, grapheme clusters)
- ANSI escape sequence preservation
- Text truncation and padding
- Syntax highlighting support

**Screen** - Virtual screen buffer
- Double-buffered rendering
- Positioned text writing
- Efficient screen updates

### Core Algorithms

**FuzzyMatchV2** (inspired by fzf):
- Modified Smith-Waterman algorithm with dynamic programming
- Scoring bonuses for:
  - Word boundaries (whitespace, delimiters)
  - CamelCase transitions
  - Consecutive character matches
  - First character matches
- Gap penalties for non-contiguous matches

**Character Classification**:
- Whitespace: Higher boundary bonus
- Delimiters (`_`, `-`, `/`, `\\`, `.`, `:`): Medium boundary bonus
- CamelCase transitions: Camel bonus
- Consecutive matches: Consecutive bonus

## Dependencies

This project uses official Apple ecosystem libraries:

- [swift-argument-parser](https://github.com/apple/swift-argument-parser) - CLI argument parsing
- [swift-system](https://github.com/apple/swift-system) - Cross-platform system calls
- [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) - Async utilities
- [swift-collections](https://github.com/apple/swift-collections) - Efficient data structures
- [swift-displaywidth](https://github.com/ainame/swift-displaywidth) - Unicode display width calculation

## Development

### Building

```bash
swift build
```

### Testing

```bash
swift test
```

### Project Structure

```
fltr/
├── Package.swift
├── README.md
├── Sources/
│   ├── FltrCSystem/        # C system shims for cross-platform
│   ├── TUI/                # Reusable TUI library
│   │   ├── RawTerminal.swift    # Terminal control
│   │   ├── KeyboardInput.swift  # Key parsing
│   │   ├── TextRenderer.swift   # Unicode/ANSI text rendering
│   │   └── Screen.swift         # Virtual screen buffer
│   └── fltr/               # Fuzzy finder executable
│       ├── fltr.swift           # Main entry point
│       ├── Matcher/             # Fuzzy matching
│       │   ├── FuzzyMatcher.swift
│       │   ├── Algorithm.swift
│       │   ├── CharClass.swift
│       │   └── MatchResult.swift
│       ├── Storage/             # Item storage
│       │   ├── Item.swift
│       │   ├── Chunk.swift
│       │   ├── ChunkList.swift
│       │   └── ItemCache.swift
│       ├── Engine/              # Parallel matching
│       │   └── MatchingEngine.swift
│       ├── Reader/              # Input reading
│       │   └── StdinReader.swift
│       └── UI/                  # User interface
│           ├── UIController.swift
│           └── UIState.swift
└── Tests/
    └── fltrTests/
```

## Platform Support

- macOS 14+ (Sonoma)
- Linux (via Swift 6.2 Static Linux SDK)

Terminal requirements:
- ANSI escape sequence support
- Access to `/dev/tty` for keyboard input

## Performance

**Optimization Techniques:**
- **Parallel Matching**: Distributes work across all CPU cores using Swift TaskGroup
  - Automatically detects CPU count (`ProcessInfo.processInfo.activeProcessorCount`)
  - Partitions items into chunks (min 100 items per chunk)
  - Only activates for datasets >1000 items (smart threshold)

- **Incremental Filtering**: Searches within previous results when query extends
  - Typing "abc" → "abcd" only searches items that matched "abc"
  - 10-100x speedup for incremental typing (most common case)

- **Hot Path Optimization**: `@inlinable` on critical functions
  - Character classification and bonus calculation inlined
  - ~5-10% additional speedup in tight loops

**Real-World Performance:**
- **Small datasets** (<1,000 items): Instant, single-threaded
- **Medium datasets** (1,000-10,000 items): Parallel matching across cores
- **Large datasets** (10,000-100,000+ items): Scales with CPU count
- **Incremental typing**: Nearly constant time regardless of dataset size

**Benchmark Examples:**
```bash
# 1,000 items: ~instant
find . -name "*.swift" | fltr

# 10,000 items: ~50ms per keystroke (4-core CPU)
find . -type f | fltr

# 100,000 items: ~200ms per keystroke (4-core CPU)
# Incremental: ~20ms after first search
```

**Comparison with fzf:**
- Similar performance on medium datasets (1K-10K items)
- Competitive on large datasets with parallel matching
- Incremental filtering gives edge on rapid typing

## License

MIT License - See LICENSE file for details.

This project includes algorithms inspired by [fzf](https://github.com/junegunn/fzf), which is also MIT licensed. See NOTICE file for full attribution.

## Contributing

Contributions welcome! Please follow these guidelines:

1. Use Swift 6.2 features (async/await, actors, etc.)
2. Maintain test coverage
3. Follow the existing code structure
4. Add documentation for new features

## Acknowledgments

- [fzf](https://github.com/junegunn/fzf) (MIT) - Fuzzy matching algorithm inspiration and scoring system
- [skim](https://github.com/lotabout/skim) (MIT) - Architecture inspiration
- Apple's Swift team for excellent ecosystem libraries

fltr is a clean-room reimplementation in Swift, inspired by fzf's algorithm concepts but written from scratch.
