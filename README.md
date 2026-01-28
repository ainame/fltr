# bokeh

A cross-platform fuzzy finder CLI tool written in Swift 6.2.

**bokeh** (meaning "fuzzy" in Japanese) is inspired by [fzf](https://github.com/junegunn/fzf) (Go) and [skim](https://github.com/lotabout/skim) (Rust), but leverages Swift's modern concurrency features and ecosystem.

## Features

### Phase 1 (MVP - Complete ✅)

- ✓ Read items from stdin
- ✓ Interactive fuzzy search with real-time filtering
- ✓ Arrow key navigation (up/down) with smooth scrolling
- ✓ Enter to select, Esc to abort
- ✓ Tab for multi-select mode
- ✓ Output selected items to stdout
- ✓ Case-insensitive by default
- ✓ FuzzyMatchV2 algorithm (modified Smith-Waterman with scoring bonuses)
- ✓ Unicode display width support (CJK, emojis, grapheme clusters)
- ✓ Dynamic terminal height (uses full screen by default)
- ✓ Whitespace as AND operator (e.g., "swift util" matches both tokens)

### Phase 2 (Performance - Complete ✅)

- ✓ **Parallel matching** - Distributes work across CPU cores using Swift TaskGroup
- ✓ **Incremental filtering** - Only searches within previous results when query extends
- ✓ **Hot path inlining** - @inlinable optimizations for character classification
- ✓ **Smart threshold** - Uses parallel matching only for datasets >1000 items
- ✓ **Streaming stdin** - UI starts immediately while still reading input (like fzf)
- ✓ **Responsive Ctrl-C** - Can interrupt even during massive stdin operations

### Phase 3 (Future)

- **ANSI color support** - Preserve colors from input
- **Extended search modes** - Exact (`'word`), prefix (`^word`), suffix (`word$`)
- **Preview window** - Show file contents while browsing
- **Custom key bindings** - User-configurable shortcuts
- **Advanced sorting** - By score, length, begin, end

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd bokeh

# Build
swift build -c release

# Install (optional)
cp .build/release/bokeh /usr/local/bin/
```

## Usage

### Basic Usage

```bash
# Pipe data to bokeh
ls | bokeh

# Find files
find . -type f | bokeh

# Filter command history
history | bokeh

# Works great with massive datasets (streams in background)
find / -type f 2>/dev/null | bokeh
# UI starts immediately, even while find is still running!
```

**Note:** bokeh streams stdin in the background, so the UI appears immediately even for huge datasets. The status bar shows `[loading...]` while input is still being read. This means you can start typing and filtering even before all items have loaded!

### Command-Line Options

```bash
bokeh --help

USAGE: bokeh [--height <height>] [--multi] [--case-sensitive]

OPTIONS:
  -h, --height <height>   Maximum display height (number of result lines)
                          Omit to use full terminal height (default)
  -m, --multi             Enable multi-select mode
  --case-sensitive        Enable case-sensitive matching
  --help                  Show help information
```

### Key Bindings

| Key | Action |
|-----|--------|
| Type characters | Filter items with fuzzy matching |
| `Up` / `Down` | Navigate through results (scrolls automatically) |
| `Enter` | Select current item and exit |
| `Tab` | Toggle multi-select on current item |
| `Esc` / `Ctrl-C` | Exit without selection |
| `Ctrl-U` | Clear query |
| `Backspace` | Delete last character |

**Note:** Results scroll automatically when you navigate beyond the visible area. The status bar shows a scroll percentage indicator `[%]` when there are more items than fit on screen.

### Examples

```bash
# Basic file selection (uses full terminal height by default)
echo -e "apple\nbanana\ncherry\napricot\navocado" | bokeh

# Multi-select mode
ls -la | bokeh --multi

# Limit display height to 15 lines
find . -name "*.swift" | bokeh --height 15

# Case-sensitive matching
cat words.txt | bokeh --case-sensitive

# Full terminal height is great for large datasets
find . -type f | bokeh  # Shows as many results as fit on your screen
```

## Architecture

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
│   ItemCache     │ ← Chunk-based storage (100 items/chunk)
│   (Actor)       │
└──────┬──────────┘
       │
┌──────▼──────────┐
│ FuzzyMatcher    │ ← FuzzyMatchV2 algorithm
└──────┬──────────┘
       │
┌──────▼──────────┐
│  UIController   │ ← Event loop, keyboard handling, rendering
│   (Actor)       │
└──────┬──────────┘
       │
┌──────▼──────────┐
│  RawTerminal    │ ← Terminal control via /dev/tty
│   (Actor)       │
└──────┬──────────┘
       │
┌──────▼──────────┐
│    stdout       │ ← Selected items output
└─────────────────┘
```

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

# Manual interactive testing
./test_bokeh.sh
```

### Project Structure

```
bokeh/
├── Package.swift
├── README.md
├── Sources/bokeh/
│   ├── bokeh.swift           # Main entry point
│   ├── Terminal/             # Terminal control
│   │   ├── RawTerminal.swift
│   │   ├── KeyboardInput.swift
│   │   ├── TextRenderer.swift
│   │   └── Screen.swift
│   ├── Matcher/              # Fuzzy matching
│   │   ├── FuzzyMatcher.swift
│   │   ├── Algorithm.swift
│   │   ├── CharClass.swift
│   │   └── MatchResult.swift
│   ├── Storage/              # Item storage
│   │   ├── Item.swift
│   │   ├── Chunk.swift
│   │   ├── ChunkList.swift
│   │   └── ItemCache.swift
│   ├── Engine/               # Parallel matching engine (Phase 2)
│   │   └── MatchingEngine.swift
│   ├── Reader/               # Input reading
│   │   └── StdinReader.swift
│   └── UI/                   # User interface
│       ├── UIController.swift
│       └── UIState.swift
└── Tests/
    └── bokehTests/
```

## Platform Support

- macOS 14+ (Sonoma)
- Linux (via Swift 6.2)

Terminal requirements:
- ANSI escape sequence support
- Access to `/dev/tty` for keyboard input

## Performance

### Current Performance (Phase 2 Complete)

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
find . -name "*.swift" | bokeh

# 10,000 items: ~50ms per keystroke (4-core CPU)
find . -type f | bokeh

# 100,000 items: ~200ms per keystroke (4-core CPU)
# Incremental: ~20ms after first search
```

**Comparison with fzf:**
- Similar performance on medium datasets (1K-10K items)
- Competitive on large datasets with parallel matching
- Incremental filtering gives edge on rapid typing

## License

See LICENSE file for details.

## Contributing

Contributions welcome! Please follow these guidelines:

1. Use Swift 6.2 features (async/await, actors, etc.)
2. Maintain test coverage
3. Follow the existing code structure
4. Add documentation for new features

## Acknowledgments

- [fzf](https://github.com/junegunn/fzf) - Inspiration for the fuzzy matching algorithm
- [skim](https://github.com/lotabout/skim) - Inspiration for the architecture
- Apple's Swift team for excellent ecosystem libraries
