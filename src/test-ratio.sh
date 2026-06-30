#!/usr/bin/env bash
#
# Test Ratio — how much of the codebase is test code vs. source code, by both
# file count and lines of code. A language-agnostic proxy for test investment
# (not a substitute for real coverage, but it needs no build and no runner).
#
# Analyzes the LOCAL working tree: it enumerates tracked files with
# `git ls-files`, classifies each as test / source / other by path and name
# convention, and counts lines. Needs no `gh` and no network.
#
# Usage: ./test-ratio.sh [path]
#   path   optional subdirectory to scope to (default: whole repo)
#
# Requirements:
#   - git (run from inside a work tree)
#   - jq (only for --json)
#

set -euo pipefail

# Source-code extensions we count (keeps docs/config/images out of the ratio).
SRC_EXT='js|jsx|ts|tsx|mjs|cjs|py|rb|go|rs|java|kt|kts|scala|c|h|cc|cpp|hpp|cxx|cs|swift|php|m|mm|dart|lua|ex|exs|erl|clj|cljs|sh|bash|zsh|pl|pm|r|jl|hs|ml|vue|svelte'

usage() {
  cat <<EOF
Usage: $(basename "$0") [path]

Reports the ratio of test code to source code, by file count and by lines of
code, with a per-top-level-directory breakdown. Files are classified as test
vs. source by path and filename convention (test/, spec/, *_test.*,
*.test.*, *.spec.*, test_*.* …).

Analyzes the LOCAL working tree — run it from inside the repo.

Arguments:
  path   Optional subdirectory to scope to (default: whole repo)

Options:
  --csv          Output per-directory CSV instead of formatted table
  --json         Output as a single JSON envelope (machine-readable)
  --healthy R    LoC ratio at/above which test investment is "healthy" (default: 0.5)
  --low R        LoC ratio below which test investment is "low" (default: 0.2)

The thresholds affect only the human-readable assessment; --json / --csv
output is unchanged by them.

Examples:
  $(basename "$0")
  $(basename "$0") src/
  $(basename "$0") --healthy 0.4 --low 0.15
  $(basename "$0") --json

Requires: git (jq for --json)
EOF
}

CSV=false
JSON=false
HEALTHY=0.5
LOW=0.2
pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --csv)  CSV=true ;;
    --json) JSON=true ;;
    --healthy)   shift; HEALTHY="${1:-}" ;;
    --healthy=*) HEALTHY="${1#*=}" ;;
    --low)       shift; LOW="${1:-}" ;;
    --low=*)     LOW="${1#*=}" ;;
    *) pos+=("$1") ;;
  esac
  shift
done
set -- "${pos[@]+"${pos[@]}"}"

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_git_repo || { usage >&2; exit 1; }
[[ "$JSON" == "true" ]] && json_preflight_local
resolve_local_repo

# Validate thresholds (non-negative numbers, integer or decimal).
if ! [[ "$HEALTHY" =~ ^[0-9]+(\.[0-9]+)?$ && "$LOW" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  [[ "$JSON" == "true" ]] && json_error BAD_ARGS "--healthy and --low must be non-negative numbers"
  echo "Error: --healthy and --low must be non-negative numbers" >&2
  exit 1
fi

SCOPE="${1:-}"

[[ "$CSV" == "false" && "$JSON" == "false" ]] && \
  echo "Computing test ratio for $REPO${SCOPE:+ ($SCOPE)} …"

# Classify a path as "test" by common conventions.
is_test_path() {
  local p="$1"
  case "$p" in
    */test/*|*/tests/*|*/__tests__/*|*/spec/*|*/specs/*|test/*|tests/*|spec/*) return 0 ;;
  esac
  local base; base=$(basename "$p")
  case "$base" in
    *_test.*|*_spec.*|*.test.*|*.spec.*|test_*.*|*Test.*|*Tests.*|*Spec.*) return 0 ;;
  esac
  return 1
}

# Aggregate counts. Keyed by top-level directory for the breakdown.
declare -A dir_src_files dir_test_files dir_src_loc dir_test_loc
src_files=0; test_files=0; src_loc=0; test_loc=0

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  # Restrict to source-code extensions so the ratio reflects code, not assets.
  ext="${path##*.}"
  [[ "$path" == *.* ]] || continue
  printf '%s' "$ext" | grep -qiE "^(${SRC_EXT})$" || continue

  full="$ROOT/$path"
  [[ -f "$full" ]] || continue
  grep -Iq . "$full" 2>/dev/null || continue   # skip binary

  loc=$(wc -l < "$full" | tr -d ' ')
  top="${path%%/*}"
  [[ "$top" == "$path" ]] && top="(root)"

  if is_test_path "$path"; then
    test_files=$(( test_files + 1 ))
    test_loc=$(( test_loc + loc ))
    dir_test_files["$top"]=$(( ${dir_test_files["$top"]:-0} + 1 ))
    dir_test_loc["$top"]=$(( ${dir_test_loc["$top"]:-0} + loc ))
  else
    src_files=$(( src_files + 1 ))
    src_loc=$(( src_loc + loc ))
    dir_src_files["$top"]=$(( ${dir_src_files["$top"]:-0} + 1 ))
    dir_src_loc["$top"]=$(( ${dir_src_loc["$top"]:-0} + loc ))
  fi
done < <(if [[ -n "$SCOPE" ]]; then git -C "$ROOT" ls-files -- "$SCOPE"; else git -C "$ROOT" ls-files; fi)

# Ratios as floats (test ÷ source); guard divide-by-zero.
file_ratio=$(awk -v t="$test_files" -v s="$src_files" 'BEGIN { printf "%.4f", (s>0 ? t/s : 0) }')
loc_ratio=$(awk -v t="$test_loc" -v s="$src_loc" 'BEGIN { printf "%.4f", (s>0 ? t/s : 0) }')

if [[ "$JSON" == "true" ]]; then
  data=$(jq -n \
    --argjson sf "$src_files" --argjson tf "$test_files" \
    --argjson sl "$src_loc" --argjson tl "$test_loc" \
    --argjson fr "$file_ratio" --argjson lr "$loc_ratio" \
    '{ source_files: $sf, test_files: $tf,
       source_loc: $sl, test_loc: $tl,
       file_ratio: $fr, loc_ratio: $lr }')
  emit_json "test-ratio" null "$data"
  exit 0
fi

# Stable, sorted list of directories seen. `|| true` tolerates the empty case
# (no matching files) under set -o pipefail.
all_dirs=$(printf '%s\n' "${!dir_src_files[@]}" "${!dir_test_files[@]}" | grep -v '^$' | sort -u || true)

if [[ "$CSV" == "true" ]]; then
  echo "Directory,SourceFiles,TestFiles,SourceLoC,TestLoC"
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    printf '"%s",%s,%s,%s,%s\n' "${d//\"/\"\"}" \
      "${dir_src_files[$d]:-0}" "${dir_test_files[$d]:-0}" \
      "${dir_src_loc[$d]:-0}" "${dir_test_loc[$d]:-0}"
  done <<< "$all_dirs"
  exit 0
fi

if (( src_files == 0 && test_files == 0 )); then
  echo "No recognized source files found${SCOPE:+ under $SCOPE}."
  exit 0
fi

printf "\nTest Ratio Analysis:\n"
printf "────────────────────\n"
printf "  Source files: %-7d (%d LoC)\n" "$src_files" "$src_loc"
printf "  Test files:   %-7d (%d LoC)\n" "$test_files" "$test_loc"
printf "  File ratio:   %s test files per source file\n" "$file_ratio"
printf "  LoC ratio:    %s test lines per source line\n" "$loc_ratio"

echo
printf "By Top-Level Directory:\n"
printf "───────────────────────\n"
printf "%-20s %-8s %-8s %-9s %-9s\n" "Directory" "Src f" "Test f" "Src LoC" "Test LoC"
printf "%s\n" "──────────────────────────────────────────────────────────────"
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  printf "%-20s %-8s %-8s %-9s %-9s\n" "$d" \
    "${dir_src_files[$d]:-0}" "${dir_test_files[$d]:-0}" \
    "${dir_src_loc[$d]:-0}" "${dir_test_loc[$d]:-0}"
done <<< "$all_dirs"

echo
printf "Assessment:\n"
printf "───────────\n"
# Compare on LoC ratio — a rough rule of thumb, not a hard target. Thresholds
# are configurable via --healthy / --low.
verdict=$(awk -v r="$loc_ratio" -v hi="$HEALTHY" -v lo="$LOW" 'BEGIN {
  if (r >= hi)      print "🟢 Healthy test investment (≥" hi " test:source LoC).";
  else if (r >= lo) print "🟡 Moderate test coverage — some areas likely thin.";
  else if (r > 0)   print "🔴 Low test investment (<" lo " test:source LoC).";
  else              print "🔴 No test code detected by convention.";
}')
echo "  $verdict"
echo "  Note: a structural proxy by convention — not a substitute for running coverage."
