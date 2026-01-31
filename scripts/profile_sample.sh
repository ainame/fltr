#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'EOF'
Usage: scripts/profile_sample.sh [--seconds N] [--output PATH] [--binary PATH] [--input PATH] [--] [args...]

Collect a stack sample for a running CLI process using macOS "sample".
Defaults:
  --seconds 10
  --output  /tmp/fltr-sample.txt
  --binary  .build/release/fltr if present, else .build/debug/fltr
EOF
}

seconds=10
output="/tmp/fltr-sample.txt"
bin=""
input=""
args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      show_help
      exit 0
      ;;
    --seconds)
      seconds="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-}"
      shift 2
      ;;
    --binary)
      bin="${2:-}"
      shift 2
      ;;
    --input)
      input="${2:-}"
      shift 2
      ;;
    --)
      shift
      args+=("$@")
      break
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$bin" ]]; then
  if [[ -x ".build/release/fltr" ]]; then
    bin=".build/release/fltr"
  else
    bin=".build/debug/fltr"
  fi
fi

if [[ ! -x "$bin" ]]; then
  echo "Binary not found or not executable: $bin" >&2
  exit 1
fi

if ! command -v sample >/dev/null 2>&1; then
  echo "sample not found. This script requires macOS." >&2
  exit 1
fi

tmp_fifo=""
cleanup() {
  if [[ -n "$tmp_fifo" && -p "$tmp_fifo" ]]; then
    rm -f "$tmp_fifo"
  fi
}
trap cleanup EXIT

if [[ -n "$input" ]]; then
  tmp_fifo="$(mktemp -u /tmp/fltr-input.XXXXXX)"
  mkfifo "$tmp_fifo"
  cat "$input" > "$tmp_fifo" &
  "$bin" "${args[@]}" < "$tmp_fifo" &
else
  "$bin" "${args[@]}" &
fi

pid=$!
sleep 0.2

echo "Sampling pid $pid for ${seconds}s -> $output"
sample "$pid" "$seconds" -file "$output"

wait "$pid" || true
echo "Done. Top of report:"
head -n 20 "$output"
