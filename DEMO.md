# bokeh Demo Guide

This guide demonstrates the key features of bokeh, the fuzzy finder CLI tool.

## Prerequisites

Build the project first:

```bash
swift build -c release
```

## Interactive Demos

### 1. Basic Fuzzy Filtering

```bash
# Create a sample list and filter it
echo -e "apple\napricot\navocado\nbanana\nblueberry\ncherry\ngrape\nkiwi\nlemon\nmango\norange\npear\nstrawberry\nwatermelon" | .build/release/bokeh
```

**Try typing:**
- `a` - Shows all fruits starting with 'a'
- `ap` - Narrows down to apple, apricot
- `ber` - Shows blueberry, strawberry (fuzzy match)
- Use `↑`/`↓` to navigate
- Press `Enter` to select

### 2. File Finder

```bash
# Find Swift files in your project
find . -name "*.swift" -type f | .build/release/bokeh
```

**Try typing:**
- `match` - Find matcher-related files
- `ui` - Find UI components
- `test` - Find test files

### 3. Multi-Select Mode

```bash
# Select multiple files
ls -1 Sources/bokeh/*/*.swift | .build/release/bokeh --multi
```

**Multi-select workflow:**
1. Type to filter items
2. Navigate with `↑`/`↓`
3. Press `Tab` to mark items (see `>` indicator)
4. Press `Enter` to output all selected items

### 4. Custom Height

```bash
# Show only 5 lines at a time
find . -type f | .build/release/bokeh --height 5
```

### 5. Case-Sensitive Search

```bash
# Case-sensitive fuzzy matching
echo -e "Apple\napple\nAPPLE\nBanana\nbanana" | .build/release/bokeh --case-sensitive
```

**Try typing:**
- `Apple` - Only matches exact case
- `apple` - Only lowercase
- `APPLE` - Only uppercase

### 6. Process List Filter

```bash
# Filter running processes (macOS)
ps aux | .build/release/bokeh --height 15
```

### 7. Git Branch Selector

```bash
# Select a git branch (if in a git repo with multiple branches)
git branch | sed 's/^[* ]*//' | .build/release/bokeh
```

### 8. Command History Search

```bash
# Search your shell history
history | awk '{$1=""; print substr($0,2)}' | .build/release/bokeh --height 20
```

## Key Bindings Reference

| Key | Action |
|-----|--------|
| Type | Filter items with fuzzy matching |
| `↑` `↓` | Navigate up/down through results |
| `Enter` | Select current item(s) and exit |
| `Tab` | Toggle multi-select on current item |
| `Esc` | Exit without selection |
| `Ctrl-C` | Exit without selection |
| `Ctrl-U` | Clear query |
| `Backspace` | Delete last character |

## UI Elements

```
┌────────────────────────────────────┐
│ > query_                           │ ← Input line with cursor
├────────────────────────────────────┤
│ > matched item 1                   │ ← Selected item (> cursor)
│   matched item 2                   │ ← Regular item
│  >matched item 3                   │ ← Multi-selected item (leading >)
│   ...                              │
├────────────────────────────────────┤
│ 150/1000 (1 selected)              │ ← Status: matches/total (selected count)
└────────────────────────────────────┘
```

## Fuzzy Matching Examples

The FuzzyMatchV2 algorithm understands various patterns:

### Consecutive Characters (Higher Score)
```bash
echo -e "application\napply\napp_lication" | .build/release/bokeh
# Type: "app"
# Result: "apply" and "application" rank higher (consecutive match)
```

### Word Boundaries (Bonus Points)
```bash
echo -e "foo_bar\nfoobar\nfoo-bar" | .build/release/bokeh
# Type: "fb"
# Result: "foo_bar" and "foo-bar" rank higher (boundary bonus)
```

### CamelCase Matching
```bash
echo -e "getUserName\ngetUser\ngetUsername" | .build/release/bokeh
# Type: "gun"
# Result: "getUserName" ranks high (CamelCase boundary)
```

## Advanced Use Cases

### Pipe to Another Command

```bash
# Select files and open in editor
find . -name "*.swift" | .build/release/bokeh | xargs -o vim

# Select and delete files (be careful!)
find . -name "*.tmp" | .build/release/bokeh --multi | xargs rm
```

### Integration with Scripts

```bash
#!/bin/bash
# Select a file and show its contents

selected=$(find . -type f | .build/release/bokeh)
if [ -n "$selected" ]; then
    cat "$selected"
fi
```

### Create an Alias

Add to your `.bashrc` or `.zshrc`:

```bash
alias fzf='~/.../bokeh/.build/release/bokeh'

# Then use it:
# vim $(find . -name "*.md" | fzf)
```

## Performance Test

Test with a large dataset:

```bash
# Generate 10,000 items
seq 1 10000 | sed 's/^/item_/' | .build/release/bokeh --height 20
```

**Expected performance:**
- Instant startup
- Real-time filtering as you type
- Smooth scrolling

## Troubleshooting

### "failedToOpenTTY" Error

This occurs when running in non-interactive mode (e.g., automated tests).
bokeh requires access to `/dev/tty` for keyboard input.

**Solution:** Run from an actual terminal, not through automation.

### Unicode Characters

bokeh correctly handles:
- CJK characters: `日本語`
- Emojis: `🍎🍌🍒`
- Combining characters: `é` (e + combining accent)

```bash
echo -e "🍎 apple\n🍌 banana\n🍒 cherry\n🥝 kiwi" | .build/release/bokeh
```

## Next Steps

After trying these demos, explore the code:

- `Sources/bokeh/Matcher/Algorithm.swift` - FuzzyMatchV2 implementation
- `Sources/bokeh/UI/UIController.swift` - Event loop and rendering
- `Sources/bokeh/Terminal/RawTerminal.swift` - Terminal control
- `Tests/bokehTests/MatcherTests.swift` - Test examples

Contribute improvements or report issues!
