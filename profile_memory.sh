#!/bin/bash
# Memory profiling script for fltr vs fzf

echo "=== Memory Profiling: fltr vs fzf ==="
echo ""

# Function to get RSS (Resident Set Size) in KB
get_memory() {
    local pid=$1
    ps -o rss= -p $pid 2>/dev/null || echo 0
}

# Test with find.txt
INPUT_FILE="./find.txt"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: $INPUT_FILE not found"
    exit 1
fi

echo "Test data: $INPUT_FILE"
wc -l "$INPUT_FILE"
wc -c "$INPUT_FILE"
echo ""

# Test fltr
echo "--- Testing fltr ---"
cat "$INPUT_FILE" | ./.build/release/fltr &
FLTR_PID=$!
sleep 2  # Wait for full load
FLTR_MEM=$(get_memory $FLTR_PID)
echo "fltr PID: $FLTR_PID"
echo "fltr RSS: ${FLTR_MEM} KB ($(echo "scale=2; $FLTR_MEM / 1024" | bc) MB)"
kill -9 $FLTR_PID 2>/dev/null
wait $FLTR_PID 2>/dev/null

echo ""

# Test fzf if available
if command -v fzf &> /dev/null; then
    echo "--- Testing fzf ---"
    cat "$INPUT_FILE" | fzf &
    FZF_PID=$!
    sleep 2  # Wait for full load
    FZF_MEM=$(get_memory $FZF_PID)
    echo "fzf PID: $FZF_PID"
    echo "fzf RSS: ${FZF_MEM} KB ($(echo "scale=2; $FZF_MEM / 1024" | bc) MB)"
    kill -9 $FZF_PID 2>/dev/null
    wait $FZF_PID 2>/dev/null

    echo ""
    echo "=== Comparison ==="
    echo "fltr: ${FLTR_MEM} KB"
    echo "fzf:  ${FZF_MEM} KB"
    DIFF=$(echo "$FLTR_MEM - $FZF_MEM" | bc)
    PCT=$(echo "scale=2; ($FLTR_MEM - $FZF_MEM) * 100 / $FZF_MEM" | bc)
    echo "Difference: ${DIFF} KB (${PCT}% more)"
else
    echo "fzf not found, skipping comparison"
fi
