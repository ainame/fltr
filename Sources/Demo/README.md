# TUI Widget Gallery

An interactive demo showcasing the widgets and utilities available in the TUI library.

## Features

This demo app demonstrates:

- **Spinner Widget** - Animated loading spinners with multiple styles (Braille, Dots, Arrow)
- **StatusBar Widget** - Status bars with count displays, selection tracking, and scroll indicators
- **HorizontalSeparator Widget** - Customizable separators with various box-drawing styles
- **ANSIColors** - Color constants and text styling utilities
- **TextRenderer** - Text truncation and formatting with ANSI support
- **Bounds** - Geometric bounds for layout and hit-testing

## Controls

- `←` `→` or `h` `l` - Navigate between pages
- `↑` `↓` or `k` `j` - Select menu items
- `Enter` or `Space` - Confirm selection
- `ESC` or `q` - Exit the demo

## Building and Running

```bash
# Build the demo
swift build --product tui-demo

# Run the demo
swift run tui-demo
```

Or use the built executable:

```bash
.build/debug/tui-demo
```

## Pages

1. **Welcome** - Introduction and navigation help
2. **Spinners** - Interactive spinner style selection with live preview
3. **Status Bars** - Examples of status bar configurations
4. **Separators** - Box-drawing separator styles (light, heavy, double, dashed)
5. **Colors & Text** - ANSI color palette and text styling examples
6. **Bounds Demo** - Geometric bounds visualization

## Code Structure

The demo is implemented as a single actor (`WidgetGallery`) that:

- Manages application state (current page, selected items, animation frames)
- Handles keyboard input with vim-style keybindings
- Renders pages using TUI widgets
- Runs an animation loop for smooth spinner animations

This demonstrates how to build interactive terminal applications using the TUI library's components.
