#!/usr/bin/env bash
#
# Contributor File Patterns — shows per-contributor PR size patterns,
# identifying focused (small PRs) vs. broad-scope (large PRs) contributors.
#
# Usage: ./contributor-file-patterns.sh owner/repo [count]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   count        number of recent merged PRs to analyze (default: 50)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [count]

Analyzes file change patterns per contributor across recent merged PRs.
Shows PR count, total/average/max files changed per author, and identifies
focused (<3 files avg) vs. broad-scope (>10 files avg) contributors.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  count        Number of recent merged PRs to analyze (default: 50)

Options:
  --csv        Output as CSV instead of formatted table
  --json       Output as a single JSON envelope (machine-readable)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 100
  $(basename "$0") my-org/my-repo 100 --csv > file-patterns.csv

Requires: gh (authenticated), jq
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

# JSON wins over CSV
[[ "$JSON" == "true" ]] && CSV=false

# Strip --csv/--json from positional args
args=()
for arg in "$@"; do
  [[ "$arg" != "--csv" && "$arg" != "--json" ]] && args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

resolve_repo "${1:-}" || { usage >&2; exit 1; }
[[ "$_REPO_FROM_ARG" == true ]] && shift

[[ "$JSON" == "true" ]] && json_preflight

COUNT="${1:-50}"

if [[ "$CSV" == "false" && "$JSON" == "false" ]]; then
  if [[ -n "${ENG_TEAM:-}" ]]; then
    echo "Analyzing file change patterns for contributors in $REPO (last $COUNT PRs, team: $ENG_TEAM) …"
  else
    echo "Analyzing file change patterns for contributors in $REPO (last $COUNT PRs) …"
  fi
fi

# Fetch recent merged PRs with author info
if [[ -n "${ENG_TEAM_MEMBERS:-}" ]]; then
  IFS=',' read -ra _members <<< "$ENG_TEAM_MEMBERS"
  _member_count=${#_members[@]}
  _per_member_limit=$(( COUNT / _member_count ))
  (( _per_member_limit < 5 )) && _per_member_limit=5

  _all_prs="[]"
  for _member in "${_members[@]}"; do
    _member_prs=$(gh pr list \
      --repo "$REPO" \
      --state merged \
      --limit "$_per_member_limit" \
      --author "$_member" \
      --json number,author 2>/dev/null || echo "[]")
    _all_prs=$(jq -s 'add' <(echo "$_all_prs") <(echo "$_member_prs"))
  done
  PR_JSON=$(echo "$_all_prs" | jq --argjson n "$COUNT" 'unique_by(.number) | sort_by(.number) | reverse | .[:$n]')
else
  PR_JSON=$(gh pr list \
    --repo "$REPO" \
    --state merged \
    --limit "$COUNT" \
    --json number,author)
fi

if [[ -z "$PR_JSON" ]] || [[ "$PR_JSON" == "[]" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "contributor-patterns" null '{"contributors":[]}'
    exit 0
  fi
  echo "No merged PRs found."
  exit 0
fi

# Temporary file to collect data
temp_file=$(mktemp)
trap "rm -f $temp_file" EXIT

# Worker: input is "<number>|<author>"; emits "<author> <files_count>".
# Skips non-team members when the team filter is active (emits nothing).
_cfp_fetch_pr() {
  local num="${1%%|*}" author="${1#*|}"
  # Skip non-team members if team filter is active
  if [[ -n "${ENG_TEAM_MEMBERS:-}" ]]; then
    echo ",${ENG_TEAM_MEMBERS}," | grep -q ",${author}," || return 0
  fi
  local files_count
  files_count=$(gh api "repos/$REPO/pulls/$num/files" --paginate 2>/dev/null | jq 'length')
  echo "$author $files_count"
}
export REPO ENG_TEAM_MEMBERS

# Run all per-PR fetches in parallel; collect into the temp file.
echo "$PR_JSON" \
  | jq -r '.[] | "\(.number)|\(.author.login)"' \
  | parallel_map _cfp_fetch_pr >> "$temp_file"

# JSON output: aggregate per-contributor stats from the collected source and
# emit a single envelope. The positional arg is a PR COUNT, not a day window,
# so window_days is null.
if [[ "$JSON" == "true" ]]; then
  data=$(sort "$temp_file" | awk '
  {
    author = $1
    files = $2
    count[author]++
    total[author] += files
  }
  END {
    printf "["
    first = 1
    for (author in count) {
      avg = total[author] / count[author]
      if (!first) printf ","
      first = 0
      printf "{\"login\":\"%s\",\"pr_count\":%d,\"avg_files_per_pr\":%g}", author, count[author], avg
    }
    printf "]"
  }' | jq '{ contributors: (sort_by(.pr_count) | reverse) }')
  emit_json "contributor-patterns" null "$data"
  exit 0
fi

# Aggregate data by contributor
if [[ "$CSV" == "false" ]]; then
  printf "\nContributor File Change Patterns:\n"
  printf "%-20s %5s %5s %5s %5s\n" "Author" "PRs" "Total" "Avg" "Max"
  printf "%s\n" "──────────────────────────────────────────────────────────"
else
  echo "Author,PRs,TotalFiles,AvgFiles,MaxFiles"
fi

# Group by author and calculate stats
sort "$temp_file" | awk -v csv="$CSV" '
{
  author = $1
  files = $2

  count[author]++
  total[author] += files

  if (files > max[author]) {
    max[author] = files
  }
}
END {
  for (author in count) {
    avg = total[author] / count[author]
    if (csv == "true") {
      printf "%s,%d,%d,%.1f,%d\n", author, count[author], total[author], avg, max[author]
    } else {
      printf "%-20s %5d %5d %5.1f %5d\n", author, count[author], total[author], avg, max[author]
    }
  }
}' | sort -k3 -nr

[[ "$CSV" == "true" ]] && exit 0

echo

# Identify patterns
printf "Pattern Analysis:\n"
printf "─────────────────\n"

# Contributors with consistently small changes (avg < 3 files)
small_change_contributors=$(sort "$temp_file" | awk '
{
  author = $1
  files = $2
  
  count[author]++
  total[author] += files
}
END {
  for (author in count) {
    if (count[author] >= 3) {
      avg = total[author] / count[author]
      if (avg < 3) {
        print author " (" avg ")"
      }
    }
  }
}' | head -5)

if [[ -n "$small_change_contributors" ]]; then
  echo "• Focused contributors (avg <3 files/PR):"
  echo "$small_change_contributors" | while read -r line; do
    echo "  - $line"
  done
  echo
fi

# Contributors with large changes (avg > 10 files)
large_change_contributors=$(sort "$temp_file" | awk '
{
  author = $1
  files = $2
  
  count[author]++
  total[author] += files
}
END {
  for (author in count) {
    if (count[author] >= 2) {
      avg = total[author] / count[author]
      if (avg > 10) {
        print author " (" avg ")"
      }
    }
  }
}' | head -5)

if [[ -n "$large_change_contributors" ]]; then
  echo "• Broad-scope contributors (avg >10 files/PR):"
  echo "$large_change_contributors" | while read -r line; do
    echo "  - $line"
  done
fi