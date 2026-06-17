#!/usr/bin/env bash
#
# Files Per PR — shows how many files each recent merged PR touched.
#
# Usage: ./files-per-pr.sh owner/repo [count]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   count        number of recent merged PRs to analyze (default: 20)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [count]

Lists files changed per recent merged PR with author and title.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  count        Number of recent merged PRs to analyze (default: 20)

Options:
  --csv        Output as CSV instead of formatted table
  --json       Output as a single JSON envelope (machine-readable)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 50
  $(basename "$0") my-org/my-repo 50 --csv > files-per-pr.csv

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

# Strip --csv/--json from positional args
args=()
for arg in "$@"; do
  [[ "$arg" != "--csv" && "$arg" != "--json" ]] && args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# parallel_map <worker_fn>
#   Reads lines from stdin and runs <worker_fn> once per line, up to
#   ENG_CONCURRENCY (default 8) at a time, concatenating their stdout.
#   The worker is a normal shell function (serialized with declare -f,
#   not export -f); each invocation receives the line as $1.
#   Input fields should be '|'-separated and each worker should emit
#   whole, short lines.
parallel_map() {
  local _worker="$1"
  xargs -P "${ENG_CONCURRENCY:-8}" -I '{}' \
    bash -c "$(declare -f "$_worker"); $_worker \"\$@\"" _ '{}'
}

resolve_repo "${1:-}" || { usage >&2; exit 1; }
[[ "$_REPO_FROM_ARG" == true ]] && shift

[[ "$JSON" == "true" ]] && json_preflight

COUNT="${1:-20}"

if [[ "$JSON" == "false" ]]; then
  if [[ -n "${ENG_TEAM:-}" ]]; then
    echo "Fetching last $COUNT merged PRs from $REPO (team: $ENG_TEAM) …"
  else
    echo "Fetching last $COUNT merged PRs from $REPO …"
  fi
fi

# Fetch recent merged PRs with basic info
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
      --json number,title,mergedAt,author,url 2>/dev/null || echo "[]")
    _all_prs=$(jq -s 'add' <(echo "$_all_prs") <(echo "$_member_prs"))
  done
  PR_JSON=$(echo "$_all_prs" | jq --argjson n "$COUNT" 'unique_by(.number) | sort_by(.mergedAt) | reverse | .[:$n]')
else
  PR_JSON=$(gh pr list \
    --repo "$REPO" \
    --state merged \
    --limit "$COUNT" \
    --json number,title,mergedAt,author,url)
fi

if [[ -z "$PR_JSON" ]] || [[ "$PR_JSON" == "[]" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "files-per-pr" null '{"count":0,"avg_files":0,"median_files":0,"prs":[]}'
    exit 0
  fi
  echo "No merged PRs found."
  exit 0
fi

total_files=0
total_prs=0
pr_records=()

# Precompute files_count per PR in parallel (num -> count), so the
# expensive per-PR `gh api .../files` calls run concurrently. The loop
# below then reads these precomputed counts, preserving output and order.
counts_file=$(mktemp)
trap "rm -f $counts_file" EXIT

_fpp_count() {
  local num="${1%%|*}"
  local c
  c=$(gh api "repos/$REPO/pulls/$num/files" --paginate 2>/dev/null | jq 'length')
  echo "$num|$c"
}
export REPO
echo "$PR_JSON" | jq -r '.[] | "\(.number)|"' | parallel_map _fpp_count > "$counts_file"

if [[ "$JSON" == "false" ]]; then
  if [[ "$CSV" == "true" ]]; then
    echo "PR,Files,Author,Title,URL"
  else
    printf "\n%-6s %-6s %-18s %-40s %s\n" "PR#" "Files" "Author" "Title" "URL"
    printf "%s\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────"
  fi
fi

# Process each PR to get file count
while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)

  num=$(echo "$pr" | jq -r '.number')
  title=$(echo "$pr" | jq -r '.title')
  author=$(echo "$pr" | jq -r '.author.login')
  url=$(echo "$pr" | jq -r '.url')

  # Look up the precomputed (parallel) file count for this PR
  files_count=$(awk -F'|' -v n="$num" '$1==n {print $2; exit}' "$counts_file")

  if [[ "$JSON" == "true" ]]; then
    pr_records+=("$(jq -n \
      --argjson number "$num" \
      --arg author "$author" \
      --argjson files_changed "$files_count" \
      --arg url "$url" \
      '{number: $number, author: $author, files_changed: $files_changed, url: $url}')")
  elif [[ "$CSV" == "true" ]]; then
    csv_title=$(echo "$title" | sed 's/"/""/g')
    printf "%s,%s,%s,\"%s\",%s\n" "$num" "$files_count" "$author" "$csv_title" "$url"
  else
    # Truncate title if too long
    truncated_title=$(echo "$title" | cut -c1-40)
    if [[ ${#title} -gt 40 ]]; then
      truncated_title="${truncated_title}…"
    fi
    printf "#%-5s %-5s %-18s %-40s %s\n" "$num" "$files_count" "$author" "$truncated_title" "$url"
  fi

  total_files=$((total_files + files_count))
  total_prs=$((total_prs + 1))
done < <(echo "$PR_JSON" | jq -r '.[] | @base64')

if [[ "$JSON" == "true" ]]; then
  if (( total_prs > 0 )); then
    avg_files=$(awk "BEGIN { printf \"%.1f\", $total_files/$total_prs }")
  else
    avg_files=0
  fi
  prs_json=$(printf '%s\n' "${pr_records[@]+"${pr_records[@]}"}" | jq -s '.')
  data=$(jq -n \
    --argjson count "$total_prs" \
    --argjson avg_files "$avg_files" \
    --argjson prs "$prs_json" \
    '{
      count: $count,
      avg_files: $avg_files,
      median_files: (
        ($prs | map(.files_changed) | sort) as $s |
        ($s | length) as $n |
        (if $n == 0 then 0
         elif ($n % 2) == 1 then $s[($n / 2 | floor)]
         else (($s[$n/2 - 1] + $s[$n/2]) / 2 | floor)
         end)
      ),
      prs: $prs
    }')
  emit_json "files-per-pr" null "$data"
  exit 0
fi

if (( total_prs > 0 )) && [[ "$CSV" == "false" ]]; then
  avg_files=$(awk "BEGIN { printf \"%.1f\", $total_files/$total_prs }")
  printf "\nAnalyzed %d PRs • Total files changed: %d • Average: %s files/PR\n" \
    "$total_prs" "$total_files" "$avg_files"
fi