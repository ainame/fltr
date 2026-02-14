#!/usr/bin/env bash
set -euo pipefail

show_help() {
  cat <<'EOF'
Usage: scripts/fuzzy_match_benchmark.sh [options]

Run throughput and quality comparisons for fltr vs FuzzyMatch suite tools
on the shared corpus/query set.

Default behavior:
  - Throughput: fltr + FuzzyMatch + nucleo (Rust)
  - Quality:    fltr + FuzzyMatch + nucleo (Rust) + fzf

Options:
  --iterations N     Throughput iterations for benchmark runners (default: 5)
  --fm-mode MODE     FuzzyMatch mode: ed, sw, or both (default: both)
  --fltr-matcher M   fltr matcher backend: utf8 or swfast (default: swfast)
  --skip-build       Reuse existing builds where possible
  --no-throughput    Skip throughput run
  --no-quality       Skip quality run
  --help, -h         Show this help

Outputs:
  /tmp/bench-fltr-latest.txt
  /tmp/bench-fuzzymatch-latest.txt
  /tmp/bench-fuzzymatch-sw-latest.txt
  /tmp/bench-nucleo-latest.txt
  /tmp/quality-fltr-latest.tsv
  /tmp/quality-fltr-latest.json
  /tmp/quality-fuzzymatch-latest.json
  /tmp/quality-fuzzymatch-sw-latest.json
  /tmp/quality-nucleo-latest.json
  /tmp/quality-fzf-latest.json
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ITERATIONS=5
FM_MODE="both"
FLTR_MATCHER="swfast"
SKIP_BUILD=false
RUN_THROUGHPUT=true
RUN_QUALITY=true

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
    --fltr-matcher)
      FLTR_MATCHER="${2:-}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --no-throughput)
      RUN_THROUGHPUT=false
      shift
      ;;
    --no-quality)
      RUN_QUALITY=false
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

case "$FLTR_MATCHER" in
  utf8|swfast) ;;
  *)
    echo "--fltr-matcher must be one of: utf8, swfast" >&2
    exit 1
    ;;
esac

FM_BENCH_SCRIPT="$REPO_ROOT/FuzzyMatch/Comparison/run-benchmarks.sh"
FM_QUALITY_SCRIPT="$REPO_ROOT/FuzzyMatch/Comparison/run-quality.py"
TSV_PATH="$REPO_ROOT/FuzzyMatch/Resources/instruments-export.tsv"
QUERIES_PATH="$REPO_ROOT/FuzzyMatch/Resources/queries.tsv"
BENCH_PKG_PATH="$REPO_ROOT/Benchmarks"

if [[ ! -x "$FM_BENCH_SCRIPT" ]]; then
  echo "FuzzyMatch throughput script not found: $FM_BENCH_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$FM_QUALITY_SCRIPT" ]]; then
  echo "FuzzyMatch quality script not found: $FM_QUALITY_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$TSV_PATH" || ! -f "$QUERIES_PATH" ]]; then
  echo "Missing corpus or queries under $REPO_ROOT/FuzzyMatch/Resources" >&2
  exit 1
fi

for cmd in swift python3 awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd not found in PATH" >&2
    exit 1
  fi
done

if ! $RUN_THROUGHPUT && ! $RUN_QUALITY; then
  echo "Nothing to do: both throughput and quality are disabled" >&2
  exit 1
fi

if $RUN_QUALITY && $SKIP_BUILD; then
  if [[ "$FM_MODE" == "ed" || "$FM_MODE" == "both" ]]; then
    if [[ ! -x "$REPO_ROOT/FuzzyMatch/Comparison/quality-fuzzymatch/.build/arm64-apple-macosx/release/quality-fuzzymatch" ]]; then
      echo "--skip-build requires prebuilt quality-fuzzymatch binary" >&2
      echo "Run once without --skip-build to build dependencies." >&2
      exit 1
    fi
  fi
  if [[ ! -x "$REPO_ROOT/FuzzyMatch/Comparison/quality-nucleo/target/release/quality-nucleo" ]]; then
    echo "--skip-build requires prebuilt quality-nucleo binary" >&2
    echo "Run once without --skip-build to build dependencies." >&2
    exit 1
  fi
fi

# Clean previous artifacts to avoid stale table rows.
rm -f /tmp/bench-fltr-latest.txt /tmp/bench-fuzzymatch-latest.txt /tmp/bench-fuzzymatch-sw-latest.txt \
      /tmp/bench-nucleo-latest.txt /tmp/quality-fltr-latest.tsv /tmp/quality-fltr-latest.json \
      /tmp/quality-fuzzymatch-latest.json /tmp/quality-fuzzymatch-sw-latest.json \
      /tmp/quality-nucleo-latest.json /tmp/quality-fzf-latest.json /tmp/quality-comparison-latest.txt

if $RUN_THROUGHPUT; then
  FM_TPUT_FLAGS=(--iterations "$ITERATIONS" --nucleo)
  case "$FM_MODE" in
    ed) FM_TPUT_FLAGS+=(--fm-ed) ;;
    sw) FM_TPUT_FLAGS+=(--fm-sw) ;;
    both) FM_TPUT_FLAGS+=(--fm-ed --fm-sw) ;;
  esac
  if $SKIP_BUILD; then
    FM_TPUT_FLAGS+=(--skip-build)
  fi

  echo "==> Running throughput benchmarks (FuzzyMatch + nucleo + fltr)"
  bash "$FM_BENCH_SCRIPT" "${FM_TPUT_FLAGS[@]}"

  if ! $SKIP_BUILD; then
    echo "==> Building fltr throughput harness"
    swift build -c release --package-path "$BENCH_PKG_PATH" --target comparison-bench-fltr >/dev/null
  fi

  echo "==> Running fltr throughput benchmark"
  swift run -c release --package-path "$BENCH_PKG_PATH" comparison-bench-fltr \
    --tsv "$TSV_PATH" \
    --queries "$QUERIES_PATH" \
    --matcher "$FLTR_MATCHER" \
    --iterations "$ITERATIONS" | tee /tmp/bench-fltr-latest.txt
fi

if $RUN_QUALITY; then
  FM_QUALITY_FLAGS=(--nucleo --fzf)
  case "$FM_MODE" in
    ed) FM_QUALITY_FLAGS+=(--fm-ed) ;;
    sw) FM_QUALITY_FLAGS+=(--fm-sw) ;;
    both) FM_QUALITY_FLAGS+=(--fm-ed --fm-sw) ;;
  esac
  if $SKIP_BUILD; then
    FM_QUALITY_FLAGS+=(--skip-build)
  fi

  echo "==> Running quality benchmarks (FuzzyMatch + nucleo + fzf)"
  python3 "$FM_QUALITY_SCRIPT" "${FM_QUALITY_FLAGS[@]}" | tee /tmp/quality-comparison-latest.txt

  if ! $SKIP_BUILD; then
    echo "==> Building fltr quality harness"
    swift build -c release --package-path "$BENCH_PKG_PATH" --target comparison-quality-fltr >/dev/null
  fi

  echo "==> Running fltr quality benchmark"
  awk -F'\t' '{print $1"\t"$2}' "$QUERIES_PATH" > /tmp/quality-queries-input.tsv
  cat /tmp/quality-queries-input.tsv \
    | swift run -c release --package-path "$BENCH_PKG_PATH" comparison-quality-fltr "$TSV_PATH" --matcher "$FLTR_MATCHER" \
    > /tmp/quality-fltr-latest.tsv

  python3 - <<'PY'
import csv, json
from collections import defaultdict

src = '/tmp/quality-fltr-latest.tsv'
dst = '/tmp/quality-fltr-latest.json'
results = defaultdict(list)
with open(src) as f:
    for row in csv.reader(f, delimiter='\t'):
        if len(row) < 6:
            continue
        q, field = row[0], row[1]
        try:
            rank = int(row[2])
        except ValueError:
            continue
        entry = {
            'rank': rank,
            'score': row[3],
            'kind': row[4] if len(row) >= 7 else 'fltr',
            'symbol': row[-2],
            'name': row[-1],
        }
        results[f"{q}\t{field}"].append(entry)

for key in list(results.keys()):
    results[key].sort(key=lambda x: x['rank'])

with open(dst, 'w') as f:
    json.dump(results, f)
PY
fi

RUN_THROUGHPUT="$RUN_THROUGHPUT" RUN_QUALITY="$RUN_QUALITY" FLTR_MATCHER="$FLTR_MATCHER" python3 - <<'PY'
import csv
import json
import os
import re
from collections import OrderedDict

queries_path = os.path.join(os.getcwd(), 'FuzzyMatch/Resources/queries.tsv')

throughput_files = OrderedDict([
    ('fltr', '/tmp/bench-fltr-latest.txt'),
    ('FuzzyMatch(ED)', '/tmp/bench-fuzzymatch-latest.txt'),
    ('FuzzyMatch(SW)', '/tmp/bench-fuzzymatch-sw-latest.txt'),
    ('nucleo', '/tmp/bench-nucleo-latest.txt'),
])

quality_files = OrderedDict([
    ('fltr', '/tmp/quality-fltr-latest.json'),
    ('FuzzyMatch(ED)', '/tmp/quality-fuzzymatch-latest.json'),
    ('FuzzyMatch(SW)', '/tmp/quality-fuzzymatch-sw-latest.json'),
    ('nucleo', '/tmp/quality-nucleo-latest.json'),
    ('fzf', '/tmp/quality-fzf-latest.json'),
])

fltr_label = f"fltr({os.environ.get('FLTR_MATCHER', 'utf8')})"

with open(queries_path) as f:
    queries = []
    for row in csv.reader(f, delimiter='\t'):
        if len(row) >= 4:
            queries.append((row[0], row[1], row[2], row[3]))
        elif len(row) >= 3:
            queries.append((row[0], row[1], row[2], '_SKIP_'))


def parse_throughput(path):
    if not os.path.exists(path):
        return None
    text = open(path).read()
    mt = re.search(r"Total time for .*: [0-9.]+ms / ([0-9.]+)ms / [0-9.]+ms", text)
    tp = re.search(r"Throughput \(median\): ([0-9.]+)M candidates/sec", text)
    pq = re.search(r"Per-query average \(median\): ([0-9.]+)ms", text)
    if not mt or not tp or not pq:
        return None
    return {
        'median_ms': float(mt.group(1)),
        'throughput_m': float(tp.group(1)),
        'per_query_ms': float(pq.group(1)),
    }


def load_quality(path):
    if not os.path.exists(path):
        return None
    data = json.load(open(path))
    out = {}
    for k, v in data.items():
        if '\t' not in k:
            continue
        q, f = k.split('\t', 1)
        vv = sorted(v, key=lambda e: int(e.get('rank', 99999)))
        out[(q, f)] = vv
    return out


def top1(res, key):
    rows = res.get(key, [])
    if not rows:
        return None
    r = rows[0]
    return (r.get('symbol', ''), r.get('name', ''))


def gt_hits(res):
    hits = 0
    total = 0
    for q, f, cat, expected in queries:
        if expected == '_SKIP_':
            continue
        total += 1
        top_n = 5 if cat in ('typo', 'prefix', 'abbreviation') else 1
        expected_lower = expected.lower()
        rows = res.get((q, f), [])
        ok = any(expected_lower in str(r.get('name', '')).lower() for r in rows[:top_n])
        if ok:
            hits += 1
    return hits, total


def result_count(res):
    return sum(1 for q, f, *_ in queries if res.get((q, f)))


run_throughput = os.environ.get('RUN_THROUGHPUT', 'true').lower() == 'true'
run_quality = os.environ.get('RUN_QUALITY', 'true').lower() == 'true'

rows = []
for tool, path in throughput_files.items():
    parsed = parse_throughput(path)
    if parsed:
        rows.append((tool, parsed))

if run_throughput:
    print("\n============================================")
    print(" Final Throughput Comparison")
    print("============================================")
    print("")
    if rows:
        print(f"{'Tool':<16} {'Median(ms)':>12} {'M/sec':>10} {'PerQuery(ms)':>14} {'vs fltr':>10}")
        print("-" * 68)

        fltr_median = None
        for t, p in rows:
            if t == 'fltr':
                fltr_median = p['median_ms']
                break

        for tool, parsed in rows:
            ratio = "-"
            if fltr_median and tool != 'fltr' and parsed['median_ms'] > 0:
                ratio = f"{(fltr_median / parsed['median_ms']):.2f}x"
            display_tool = fltr_label if tool == 'fltr' else tool
            print(f"{display_tool:<16} {parsed['median_ms']:>12.1f} {parsed['throughput_m']:>10.1f} {parsed['per_query_ms']:>14.2f} {ratio:>10}")
    else:
        print("(no throughput results found)")

qres = []
for tool, path in quality_files.items():
    parsed = load_quality(path)
    if parsed is not None:
        qres.append((tool, parsed))

if run_quality:
    print("\n============================================")
    print(" Final Quality Comparison")
    print("============================================")
    print("")
    if qres:
        print(f"{'Tool':<16} {'Results':>10} {'GT Hits':>12} {'GT %':>8} {'Top1 vs FM(ED)':>16} {'Top1 vs fltr':>14}")
        print("-" * 84)

        fm = dict((t, r) for t, r in qres).get('FuzzyMatch(ED)')
        fl = dict((t, r) for t, r in qres).get('fltr')

        for tool, res in qres:
            rc = result_count(res)
            hits, total = gt_hits(res)
            gt_pct = (100.0 * hits / total) if total else 0.0

            agree_fm = "-"
            if fm is not None and tool != 'FuzzyMatch(ED)':
                a = 0
                for q, f, *_ in queries:
                    t1 = top1(res, (q, f))
                    t2 = top1(fm, (q, f))
                    if t1 and t2 and t1 == t2:
                        a += 1
                agree_fm = f"{a}/{len(queries)}"

            agree_fl = "-"
            if fl is not None and tool != 'fltr':
                a = 0
                for q, f, *_ in queries:
                    t1 = top1(res, (q, f))
                    t2 = top1(fl, (q, f))
                    if t1 and t2 and t1 == t2:
                        a += 1
                agree_fl = f"{a}/{len(queries)}"

            display_tool = fltr_label if tool == 'fltr' else tool
            print(f"{display_tool:<16} {f'{rc}/{len(queries)}':>10} {f'{hits}/{total}':>12} {gt_pct:>7.1f}% {agree_fm:>16} {agree_fl:>14}")
    else:
        print("(no quality results found)")

print("\nSaved outputs:")
for p in [
    '/tmp/bench-fltr-latest.txt',
    '/tmp/bench-fuzzymatch-latest.txt',
    '/tmp/bench-fuzzymatch-sw-latest.txt',
    '/tmp/bench-nucleo-latest.txt',
    '/tmp/quality-fltr-latest.tsv',
    '/tmp/quality-fltr-latest.json',
    '/tmp/quality-fuzzymatch-latest.json',
    '/tmp/quality-fuzzymatch-sw-latest.json',
    '/tmp/quality-nucleo-latest.json',
    '/tmp/quality-fzf-latest.json',
]:
    if os.path.exists(p):
        print(f"  {p}")
PY
