#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'EOF'
Usage: scripts/fuzzy_match_benchmark.sh [--iterations N] [--fm-mode ed|sw|both] [--skip-build]

Run FuzzyMatch comparison benchmark and fltr benchmark against the same corpus/queries,
then print a compact throughput comparison summary.

Options:
  --iterations N   Number of timed iterations for both tools (default: 5)
  --fm-mode MODE   FuzzyMatch mode: ed, sw, or both (default: ed)
  --skip-build     Pass --skip-build to FuzzyMatch runner and skip fltr pre-build
  --help, -h       Show this help

Outputs:
  /tmp/bench-fuzzymatch-latest.txt       (FuzzyMatch ED, if enabled)
  /tmp/bench-fuzzymatch-sw-latest.txt    (FuzzyMatch SW, if enabled)
  /tmp/bench-fltr-latest.txt             (fltr benchmark output)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ITERATIONS=5
FM_MODE="ed"
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)
      ITERATIONS="${2:-}"
      shift 2
      ;;
    --fm-mode)
      FM_MODE="${2:-}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help >&2
      exit 1
      ;;
  esac
done

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$ITERATIONS" -lt 1 ]]; then
  echo "--iterations must be a positive integer" >&2
  exit 1
fi

case "$FM_MODE" in
  ed|sw|both) ;;
  *)
    echo "--fm-mode must be one of: ed, sw, both" >&2
    exit 1
    ;;
esac

FM_SCRIPT="$REPO_ROOT/FuzzyMatch/Comparison/run-benchmarks.sh"
TSV_PATH="$REPO_ROOT/FuzzyMatch/Resources/instruments-export.tsv"
QUERIES_PATH="$REPO_ROOT/FuzzyMatch/Resources/queries.tsv"

if [[ ! -x "$FM_SCRIPT" ]]; then
  echo "FuzzyMatch benchmark script not found: $FM_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$TSV_PATH" || ! -f "$QUERIES_PATH" ]]; then
  echo "Missing corpus or queries under $REPO_ROOT/FuzzyMatch/Resources" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found in PATH" >&2
  exit 1
fi

FM_FLAGS=(--iterations "$ITERATIONS")
case "$FM_MODE" in
  ed) FM_FLAGS+=(--fm-ed) ;;
  sw) FM_FLAGS+=(--fm-sw) ;;
  both) FM_FLAGS+=(--fm-ed --fm-sw) ;;
esac
if $SKIP_BUILD; then
  FM_FLAGS+=(--skip-build)
fi

echo "==> Running FuzzyMatch benchmark ($FM_MODE, iterations=$ITERATIONS)"
bash "$FM_SCRIPT" "${FM_FLAGS[@]}"

if ! $SKIP_BUILD; then
  echo "==> Building fltr benchmark harness"
  swift build -c release --package-path "$REPO_ROOT/Benchmarks" --target comparison-bench-fltr >/dev/null
fi

echo "==> Running fltr benchmark (iterations=$ITERATIONS)"
swift run -c release --package-path "$REPO_ROOT/Benchmarks" comparison-bench-fltr \
  --tsv "$TSV_PATH" \
  --queries "$QUERIES_PATH" \
  --iterations "$ITERATIONS" | tee /tmp/bench-fltr-latest.txt

extract_median_ms() {
  local file="$1"
  sed -n 's/^Total time for .*: [0-9.]*ms \/ \([0-9.]*\)ms \/ [0-9.]*ms$/\1/p' "$file" | tail -1
}

extract_throughput_m() {
  local file="$1"
  sed -n 's/^Throughput (median): \([0-9.]*\)M candidates\/sec$/\1/p' "$file" | tail -1
}

FLTR_FILE="/tmp/bench-fltr-latest.txt"
FLTR_MEDIAN="$(extract_median_ms "$FLTR_FILE")"
FLTR_TPUT="$(extract_throughput_m "$FLTR_FILE")"

if [[ -z "$FLTR_MEDIAN" || -z "$FLTR_TPUT" ]]; then
  echo "Failed to parse fltr benchmark output: $FLTR_FILE" >&2
  exit 1
fi

printf '\n==> Throughput summary\n\n'
printf '%-20s %14s %14s\n' 'Tool' 'Median total' 'Throughput'
printf '%-20s %14s %14s\n' 'fltr' "${FLTR_MEDIAN}ms" "${FLTR_TPUT}M/sec"

print_vs_fltr() {
  local label="$1"
  local file="$2"
  local median tput ratio

  median="$(extract_median_ms "$file")"
  tput="$(extract_throughput_m "$file")"
  if [[ -z "$median" || -z "$tput" ]]; then
    echo "Failed to parse $label output: $file" >&2
    exit 1
  fi

  printf '%-20s %14s %14s\n' "$label" "${median}ms" "${tput}M/sec"

  ratio="$(awk -v fltr="$FLTR_MEDIAN" -v other="$median" 'BEGIN { if (other > 0) printf "%.2fx", fltr/other; else print "n/a" }')"
  printf '  fltr/%s median time: %s\n' "$label" "$ratio"
}

if [[ "$FM_MODE" == "ed" || "$FM_MODE" == "both" ]]; then
  print_vs_fltr "FuzzyMatch(ED)" "/tmp/bench-fuzzymatch-latest.txt"
fi
if [[ "$FM_MODE" == "sw" || "$FM_MODE" == "both" ]]; then
  print_vs_fltr "FuzzyMatch(SW)" "/tmp/bench-fuzzymatch-sw-latest.txt"
fi

echo ""
echo "Saved outputs:"
echo "  /tmp/bench-fltr-latest.txt"
if [[ -f /tmp/bench-fuzzymatch-latest.txt ]]; then
  echo "  /tmp/bench-fuzzymatch-latest.txt"
fi
if [[ -f /tmp/bench-fuzzymatch-sw-latest.txt ]]; then
  echo "  /tmp/bench-fuzzymatch-sw-latest.txt"
fi
