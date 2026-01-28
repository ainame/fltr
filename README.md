# bokeh

A cross-platform fuzzy finder CLI tool written in Swift 6.2.

**bokeh** (meaning "fuzzy" in Japanese) is inspired by [fzf](https://github.com/junegunn/fzf) (Go) and [skim](https://github.com/lotabout/skim) (Rust), but leverages Swift's modern concurrency features and ecosystem.

## Features

### Phase 1 (MVP - Current)

- ✓ Read items from stdin
- ✓ Interactive fuzzy search with real-time filtering
- ✓ Arrow key navigation (up/down)
- ✓ Enter to select, Esc to abort
- ✓ Tab for multi-select mode
- ✓ Output selected items to stdout
- ✓ Case-insensitive by default
- ✓ FuzzyMatchV2 algorithm (modified Smith-Waterman with scoring bonuses)
- ✓ Unicode display width support (CJK, emojis, grapheme clusters)

### Future Phases

- **Phase 2**: Parallel matching, ANSI color support, extended search modes
- **Phase 3**: Preview window, custom key bindings, advanced sorting

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
```

### Command-Line Options

```bash
bokeh --help

USAGE: bokeh [--height <height>] [--multi] [--case-sensitive]

OPTIONS:
  -h, --height <height>   Display height (number of result lines) (default: 10)
  -m, --multi             Enable multi-select mode
  --case-sensitive        Enable case-sensitive matching
  --help                  Show help information
```

### Key Bindings

| Key | Action |
|-----|--------|
| Type characters | Filter items with fuzzy matching |
| `Up` / `Down` | Navigate through results |
| `Enter` | Select current item and exit |
| `Tab` | Toggle multi-select on current item |
| `Esc` / `Ctrl-C` | Exit without selection |
| `Ctrl-U` | Clear query |
| `Backspace` | Delete last character |

### Examples

```bash
# Basic file selection
echo -e "apple\nbanana\ncherry\napricot\navocado" | bokeh

# Multi-select mode
ls -la | bokeh --multi

# Custom height
find . -name "*.swift" | bokeh --height 15

# Case-sensitive matching
cat words.txt | bokeh --case-sensitive
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

### Phase 1 (Current)
- Handles up to 10,000 items smoothly
- Real-time filtering with no visible lag
- Chunk-based storage (100 items per chunk)

### Phase 2 (Planned)
- Parallel matching with Swift TaskGroup
- Handles 100,000+ items efficiently
- Result caching for repeated queries

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
