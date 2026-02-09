#!/bin/bash
# Heap profiling for fltr to find memory usage

set -e

echo "=== Building release binary ==="
swift build -c release
echo ""

echo "=== Starting fltr in background ==="
echo "You need to manually run this in a separate terminal:"
echo ""
echo "  cat find.txt | ./.build/release/fltr"
echo ""
echo "Then press ENTER here to continue..."
read -r

echo ""
echo "Finding fltr process..."
FLTR_PID=$(pgrep -f "\.build/release/fltr" | head -1)

if [ -z "$FLTR_PID" ]; then
    echo "ERROR: fltr process not found!"
    echo "Make sure you started it in another terminal"
    exit 1
fi

echo "Found fltr PID: $FLTR_PID"
echo ""

# Wait a bit for data to load
echo "Waiting 3 seconds for data to load..."
sleep 3

echo ""
echo "=== Memory Statistics ==="
ps -o pid,rss,vsz,command -p $FLTR_PID
RSS=$(ps -o rss= -p $FLTR_PID | tr -d ' ')
echo ""
echo "RSS (Resident Set Size): $RSS KB = $((RSS / 1024)) MB"
echo ""

echo "=== Heap Analysis ==="
echo "Running heap command (may take 10-20 seconds)..."
heap $FLTR_PID > /tmp/fltr_heap.txt 2>&1

echo ""
echo "=== Top Memory Regions ==="
grep -A30 "MALLOC ZONE" /tmp/fltr_heap.txt | head -35

echo ""
echo "=== Largest Allocations ==="
echo "Sorting by size..."
grep -E "^[0-9]" /tmp/fltr_heap.txt | sort -k2 -n -r | head -20

echo ""
echo "=== Full heap output saved to /tmp/fltr_heap.txt ==="
echo ""
echo "To analyze:"
echo "  less /tmp/fltr_heap.txt"
echo "  grep 'Array' /tmp/fltr_heap.txt"
echo "  grep 'String' /tmp/fltr_heap.txt"
echo ""
echo "Press ENTER to kill fltr and finish..."
read -r

kill $FLTR_PID 2>/dev/null || true
echo "Done!"
