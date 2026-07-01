#!/usr/bin/env bash
#
# Hotspots — refactoring targets, found by joining change frequency (churn)
# with code size (a complexity proxy). A file that changes often AND is large
# is where refactoring pays off most. This is the churn × complexity model
# popularized by CodeScene.
#
# Unlike the API-based metrics, this analyzes the LOCAL working tree: churn
# comes from `git log` and size from the checked-out files, so it needs no
# `gh` and no network. Run it from inside the repo you want to analyze.
#
# Usage: ./hotspots.sh [days] [min_changes]
#   days          lookback window in days for churn (default: 90)
#   min_changes   minimum commits touching a file to consider it (default: 3)
#
# Requirements:
#   - git (run from inside a work tree)
#   - jq (only for --json)
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [days] [min_changes]

Surfaces refactoring targets by combining how often a file changes (churn,
from git history) with how large it is (a complexity proxy). Files that are
both frequently changed and large score highest.

Analyzes the LOCAL working tree — run it from inside the repo.

Arguments:
  days          Lookback window in days for churn (default: 90)
  min_changes   Minimum commits touching a file to consider it (default: 3)

Options:
  --csv             Output as CSV instead of formatted table
  --json            Output as a single JSON envelope (machine-readable)
  --high-lines N    Line count for the high-risk tier (default: 200)
  --med-lines N     Line count for the medium-risk tier (default: 50)

The tier cutoffs affect only the human-readable risk assessment; --json /
--csv output is unchanged by them.

Examples:
  $(basename "$0")
  $(basename "$0") 180 5
  $(basename "$0") 90 --high-lines 300 --med-lines 80
  $(basename "$0") 90 --json

Requires: git (jq for --json)
EOF
}

CSV=false
JSON=false
HIGH_LINES=200
MED_LINES=50
pos=()
# need_value <flag>: fail clearly when a value-taking flag has no argument,
# instead of shifting past the end and silently aborting under `set -e`.
need_value() {
  [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; exit 1; }
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --csv)  CSV=true ;;
    --json) JSON=true ;;
    --high-lines)   need_value "$@"; HIGH_LINES="$2"; shift ;;
    --high-lines=*) HIGH_LINES="${1#*=}" ;;
    --med-lines)    need_value "$@"; MED_LINES="$2"; shift ;;
    --med-lines=*)  MED_LINES="${1#*=}" ;;
    *) pos+=("$1") ;;
  esac
  shift
done
set -- "${pos[@]+"${pos[@]}"}"

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[[ "$JSON" == "true" ]] && json_preflight_local
require_git_repo || { usage >&2; exit 1; }
resolve_local_repo

# Validate tier cutoffs (non-negative integers).
if ! [[ "$HIGH_LINES" =~ ^[0-9]+$ && "$MED_LINES" =~ ^[0-9]+$ ]]; then
  [[ "$JSON" == "true" ]] && json_error BAD_ARGS "--high-lines and --med-lines must be non-negative integers"
  echo "Error: --high-lines and --med-lines must be non-negative integers" >&2
  exit 1
fi

DAYS="${1:-90}"
MIN_CHANGES="${2:-3}"

# Validate positionals (non-negative integers). Guards emit_json's --argjson
# window later, which would otherwise surface a raw jq error.
if ! [[ "$DAYS" =~ ^[0-9]+$ && "$MIN_CHANGES" =~ ^[0-9]+$ ]]; then
  [[ "$JSON" == "true" ]] && json_error BAD_ARGS "days and min_changes must be non-negative integers"
  echo "Error: days and min_changes must be non-negative integers" >&2
  exit 1
fi

[[ "$CSV" == "false" && "$JSON" == "false" ]] && \
  echo "Analyzing hotspots for $REPO (last $DAYS days, min $MIN_CHANGES changes) …"

# Churn: count commits touching each path within the window. Blank lines from
# the empty --pretty format are dropped before counting. Counting happens in a
# single awk pass keyed on the whole line, so paths that contain consecutive
# spaces (or other internal whitespace) survive verbatim — `uniq -c` + field
# surgery would collapse them and break the ls-files join below.
# `|| true` keeps an empty window (no matching lines under pipefail) from
# tripping `set -e` before the empty-result handler runs.
churn=$(git -C "$ROOT" log --since="${DAYS} days ago" --pretty=format: --name-only 2>/dev/null \
  | awk -v min="$MIN_CHANGES" '
      $0 != "" { count[$0]++ }
      END { for (p in count) if (count[p] >= min) print count[p] "\t" p }' || true)

emit_empty() {
  if [[ "$JSON" == "true" ]]; then
    emit_json "hotspots" "$DAYS" '{"files":[],"hotspot_count":0}'
  elif [[ "$CSV" == "true" ]]; then
    echo "File,Changes,Lines,Score"
  else
    echo "No files changed ≥$MIN_CHANGES times in the last $DAYS days — nothing hot here."
  fi
  exit 0
}

[[ -z "$churn" ]] && emit_empty

# Membership set of currently-tracked files (drops files deleted since they
# churned, and anything git-ignored).
declare -A tracked
while IFS= read -r f; do tracked["$f"]=1; done < <(git -C "$ROOT" ls-files)

# Join churn with line counts. score = changes × lines.
# records: "score\tchanges\tlines\tpath" (skips deleted/binary files).
records=""
while IFS=$'\t' read -r count path; do
  [[ -n "$path" ]] || continue
  [[ -n "${tracked[$path]:-}" ]] || continue
  full="$ROOT/$path"
  [[ -f "$full" ]] || continue
  grep -Iq . "$full" 2>/dev/null || continue   # skip binary files
  lines=$(wc -l < "$full" | tr -d ' ')
  score=$(( count * lines ))
  records+="${score}	${count}	${lines}	${path}"$'\n'
done <<< "$churn"

records=$(printf '%s' "$records" | grep -v '^$' || true)
[[ -z "$records" ]] && emit_empty

# Sort by score desc, then changes desc.
records=$(printf '%s\n' "$records" | sort -t$'\t' -k1,1nr -k2,2nr)

if [[ "$JSON" == "true" ]]; then
  files_json=$(printf '%s\n' "$records" | jq -R -s '
    [ split("\n")[] | select(length > 0) | split("\t")
      | { path: .[3],
          change_count: (.[1] | tonumber),
          line_count: (.[2] | tonumber),
          score: (.[0] | tonumber) } ]')
  data=$(jq -n --argjson files "$files_json" \
    '{ files: $files, hotspot_count: ($files | length) }')
  emit_json "hotspots" "$DAYS" "$data"
  exit 0
fi

if [[ "$CSV" == "true" ]]; then
  echo "File,Changes,Lines,Score"
  printf '%s\n' "$records" | while IFS=$'\t' read -r score count lines path; do
    csv_path=$(echo "$path" | sed 's/"/""/g')
    printf '"%s",%s,%s,%s\n' "$csv_path" "$count" "$lines" "$score"
  done
  exit 0
fi

total=$(printf '%s\n' "$records" | grep -c . || true)

printf "\nHotspots (churn × size):\n"
printf "────────────────────────\n"
printf "%-6s %-7s %-8s %s\n" "Chgs" "Lines" "Score" "File"
printf "%s\n" "──────────────────────────────────────────────────────────────────────"
printf '%s\n' "$records" | head -20 | while IFS=$'\t' read -r score count lines path; do
  printf "%-6s %-7s %-8s %s\n" "$count" "$lines" "$score" "$path"
done
if (( total > 20 )); then
  printf "  … and %d more\n" "$(( total - 20 ))"
fi

# Risk tiers: a hotspot is risky when it is BOTH churned and large. The line
# cutoffs are configurable via --high-lines / --med-lines.
high=$(printf '%s\n' "$records" | awk -F'\t' -v h="$HIGH_LINES" '$3 >= h')
med=$(printf '%s\n'  "$records" | awk -F'\t' -v h="$HIGH_LINES" -v m="$MED_LINES" '$3 >= m && $3 < h')
high_n=$(printf '%s' "$high" | grep -c . || true)
med_n=$(printf '%s'  "$med"  | grep -c . || true)

echo
printf "Risk Assessment:\n"
printf "────────────────\n"
if (( high_n > 0 )); then
  echo "• 🔴 High: $high_n hotspot(s) ≥${HIGH_LINES} lines — large, frequently-changed files."
  echo "  Prime candidates to split up and shore up with tests."
fi
if (( med_n > 0 )); then
  echo "• 🟡 Medium: $med_n hotspot(s) ${MED_LINES}–$(( HIGH_LINES - 1 )) lines — watch for growth."
fi
if (( high_n == 0 && med_n == 0 )); then
  echo "• 🟢 Churn is concentrated in small files — low refactoring pressure."
fi

top=$(printf '%s\n' "$records" | head -1)
if [[ -n "$top" ]]; then
  t_count=$(echo "$top" | cut -f2)
  t_lines=$(echo "$top" | cut -f3)
  t_path=$(echo "$top" | cut -f4)
  echo
  printf "Top Hotspot:\n"
  printf "────────────\n"
  printf "• %s — %s changes across %s lines\n" "$t_path" "$t_count" "$t_lines"
fi
