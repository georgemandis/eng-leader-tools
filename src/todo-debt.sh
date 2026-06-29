#!/usr/bin/env bash
#
# TODO Debt — counts and locates self-flagged technical debt markers
# (TODO / FIXME / HACK / XXX) across the tracked files in the repo. A cheap,
# language-agnostic proxy for "debt the team already knows about."
#
# Analyzes the LOCAL working tree via `git grep` (tracked files only, so it
# respects .gitignore and never wades into node_modules / vendored code).
# Needs no `gh` and no network — run it from inside the repo.
#
# Usage: ./todo-debt.sh [path]
#   path   optional subdirectory to scope the scan to (default: whole repo)
#
# Requirements:
#   - git (run from inside a work tree)
#   - jq (only for --json)
#

set -euo pipefail

MARKERS="TODO|FIXME|HACK|XXX"

usage() {
  cat <<EOF
Usage: $(basename "$0") [path]

Counts and locates technical-debt markers ($MARKERS) across the
repository's tracked files. Reports totals by marker type, the files with
the most markers, and the directories carrying the most debt.

Analyzes the LOCAL working tree — run it from inside the repo.

Arguments:
  path   Optional subdirectory to scope the scan to (default: whole repo)

Options:
  --csv         Output as CSV (File,Count) instead of formatted table
  --json        Output as a single JSON envelope (machine-readable)

Examples:
  $(basename "$0")
  $(basename "$0") src/
  $(basename "$0") --json

Requires: git (jq for --json)
EOF
}

CSV=false
JSON=false
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --csv) CSV=true ;;
    --json) JSON=true ;;
  esac
done

args=()
for arg in "$@"; do
  [[ "$arg" != "--csv" && "$arg" != "--json" ]] && args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_git_repo || { usage >&2; exit 1; }
[[ "$JSON" == "true" ]] && json_preflight_local
resolve_local_repo

SCOPE="${1:-}"

[[ "$CSV" == "false" && "$JSON" == "false" ]] && \
  echo "Scanning for TODO debt in $REPO${SCOPE:+ ($SCOPE)} …"

# git grep over tracked text files only (-I). -w keeps matches to whole words
# so "TODOs" / identifiers don't false-positive. -o emits one record PER marker
# occurrence (a line with two markers yields two records), formatted
# "path:line:MARKER", so every count below is occurrence-based and consistent.
# Non-zero exit just means no matches — tolerate it.
if [[ -n "$SCOPE" ]]; then
  matches=$(git -C "$ROOT" grep -noIw -E "$MARKERS" -- "$SCOPE" 2>/dev/null || true)
else
  matches=$(git -C "$ROOT" grep -noIw -E "$MARKERS" 2>/dev/null || true)
fi

emit_empty() {
  if [[ "$JSON" == "true" ]]; then
    emit_json "todo-debt" null \
      '{"total":0,"by_type":{"TODO":0,"FIXME":0,"HACK":0,"XXX":0},"files":[],"file_count":0}'
  elif [[ "$CSV" == "true" ]]; then
    echo "File,Count"
  else
    echo "🟢 No $MARKERS markers found — clean tree."
  fi
  exit 0
}

[[ -z "$matches" ]] && emit_empty

# The marker is always the final colon-delimited field of each record.
count_marker() { printf '%s\n' "$matches" | awk -F: -v m="$1" '$NF==m' | grep -c . || true; }
todo_n=$(count_marker "TODO")
fixme_n=$(count_marker "FIXME")
hack_n=$(count_marker "HACK")
xxx_n=$(count_marker "XXX")
total=$(printf '%s\n' "$matches" | grep -c . || true)

# Per-file occurrence counts, most debt first (sums to total).
per_file=$(printf '%s\n' "$matches" | cut -d: -f1 | sort | uniq -c | sort -nr \
  | awk '{ c=$1; $1=""; sub(/^ /,""); print c "\t" $0 }')

if [[ "$JSON" == "true" ]]; then
  files_json=$(printf '%s\n' "$per_file" | jq -R -s '
    [ split("\n")[] | select(length > 0) | split("\t")
      | { path: .[1], count: (.[0] | tonumber) } ]')
  data=$(jq -n \
    --argjson files "$files_json" \
    --argjson total "$total" \
    --argjson todo "$todo_n" --argjson fixme "$fixme_n" \
    --argjson hack "$hack_n" --argjson xxx "$xxx_n" \
    '{ total: $total,
       by_type: { TODO: $todo, FIXME: $fixme, HACK: $hack, XXX: $xxx },
       files: $files,
       file_count: ($files | length) }')
  emit_json "todo-debt" null "$data"
  exit 0
fi

if [[ "$CSV" == "true" ]]; then
  echo "File,Count"
  printf '%s\n' "$per_file" | while IFS=$'\t' read -r c path; do
    csv_path=$(echo "$path" | sed 's/"/""/g')
    printf '"%s",%s\n' "$csv_path" "$c"
  done
  exit 0
fi

file_count=$(printf '%s\n' "$per_file" | grep -c . || true)

printf "\nTODO Debt Analysis:\n"
printf "───────────────────\n"
printf "  Total markers:   %d across %d file(s)\n" "$total" "$file_count"
printf "  TODO:  %-5d  FIXME: %-5d\n" "$todo_n" "$fixme_n"
printf "  HACK:  %-5d  XXX:   %-5d\n" "$hack_n" "$xxx_n"

echo
printf "Files With Most Debt:\n"
printf "─────────────────────\n"
printf "%-6s %s\n" "Count" "File"
printf "%s\n" "──────────────────────────────────────────────────────────"
printf '%s\n' "$per_file" | head -15 | while IFS=$'\t' read -r c path; do
  printf "%-6s %s\n" "$c" "$path"
done
if (( file_count > 15 )); then
  printf "  … and %d more file(s)\n" "$(( file_count - 15 ))"
fi

echo
printf "Top Debt Directories:\n"
printf "─────────────────────\n"
printf '%s\n' "$per_file" | while IFS=$'\t' read -r c path; do
  d=$(dirname "$path")
  printf "%s\t%s\n" "$c" "$d"
done | awk -F'\t' '{ sum[$2]+=$1 } END { for (d in sum) printf "%d\t%s\n", sum[d], d }' \
  | sort -nr | head -5 | while IFS=$'\t' read -r c d; do
  printf "%-6s %s\n" "$c" "$d"
done
