#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'EOF'
Usage: scripts/profile_xctrace.sh [--template NAME] [--output PATH] [--binary PATH] [--input PATH] [--] [args...]

Record a Time Profiler trace using xctrace (no GUI needed).
Defaults:
  --template "Time Profiler"
  --output   /tmp/fltr-timeprofiler.trace
  --binary   .build/release/fltr if present, else .build/debug/fltr
EOF
}

template="Time Profiler"
output="/tmp/fltr-timeprofiler.trace"
bin=""
input=""
args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      show_help
      exit 0
      ;;
    --template)
      template="${2:-}"
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

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun not found. This script requires Xcode command line tools." >&2
  exit 1
fi

echo "Recording trace: $output"
echo "Template: $template"
echo "Binary: $bin ${args[*]}"

if [[ -n "$input" ]]; then
  xcrun xctrace record \
    --template "$template" \
    --output "$output" \
    --launch -- "$bin" "${args[@]}" < "$input"
else
  xcrun xctrace record \
    --template "$template" \
    --output "$output" \
    --launch -- "$bin" "${args[@]}"
fi

echo "Done. Open in Instruments:"
echo "  open -a Instruments \"$output\""
