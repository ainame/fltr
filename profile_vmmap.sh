#!/bin/bash
# Use vmmap to analyze memory regions

set -e

echo "=== Memory Region Analysis with vmmap ==="
echo ""
echo "This will show detailed memory breakdown"
echo ""
echo "Step 1: In one terminal, run:"
echo "  cat find.txt | ./.build/release/fltr"
echo ""
echo "Step 2: Press ENTER here when fltr has loaded the data..."
read -r

FLTR_PID=$(pgrep -f "\.build/release/fltr" | head -1)

if [ -z "$FLTR_PID" ]; then
    echo "ERROR: fltr not running!"
    exit 1
fi

echo "Found PID: $FLTR_PID"
echo ""

echo "=== Overall Memory ==="
ps -o pid,rss,vsz -p $FLTR_PID
RSS=$(ps -o rss= -p $FLTR_PID | tr -d ' ')
echo "RSS: $((RSS / 1024)) MB"
echo ""

echo "=== Memory Regions (vmmap) ==="
vmmap $FLTR_PID | grep -E "REGION TYPE|MALLOC|Stack|TOTAL"

echo ""
echo "=== Detailed MALLOC breakdown ==="
vmmap $FLTR_PID | grep "MALLOC" | head -20

echo ""
echo "=== Saving full vmmap to /tmp/fltr_vmmap.txt ==="
vmmap $FLTR_PID > /tmp/fltr_vmmap.txt

echo ""
echo "Key regions to check in /tmp/fltr_vmmap.txt:"
echo "  - MALLOC_LARGE: Large allocations (arrays)"
echo "  - MALLOC_TINY: Small allocations"
echo "  - Stack: Thread stacks"
echo ""
echo "To analyze:"
echo "  grep 'MALLOC_LARGE' /tmp/fltr_vmmap.txt"
echo "  grep 'Array' /tmp/fltr_vmmap.txt"
echo ""

kill $FLTR_PID 2>/dev/null || true
echo "Done!"
