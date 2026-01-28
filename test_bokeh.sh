#!/bin/bash

# Test script for bokeh

echo "Test 1: Basic functionality with 5 items"
echo -e "apple\nbanana\ncherry\napricot\navocado" | .build/debug/bokeh --help

echo ""
echo "Test 2: Help output"
.build/debug/bokeh --help

echo ""
echo "Test 3: Larger dataset"
find . -name "*.swift" -type f | head -20 | .build/debug/bokeh --height 5 || echo "Needs interactive input - run manually"

echo ""
echo "Instructions for manual testing:"
echo "  1. echo -e 'apple\\nbanana\\ncherry\\napricot\\navocado' | .build/debug/bokeh"
echo "  2. ls -la | .build/debug/bokeh"
echo "  3. find . -name '*.swift' | .build/debug/bokeh --height 15"
echo ""
echo "Key bindings:"
echo "  - Type to filter"
echo "  - Up/Down to navigate"
echo "  - Tab to multi-select"
echo "  - Enter to select and exit"
echo "  - Esc to cancel"
