#!/usr/bin/env bash
#
# Lead Time to Change — measures average time from PR creation to merge.
#
# Usage: ./leadtimetochange.sh owner/repo [days]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   days         lookback window in days (default: 30)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [days]

Measures average lead time from PR creation to merge.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  days         Lookback window in days (default: 30)
  --csv        Output as CSV instead of formatted table
  --json       Output as a single JSON envelope (machine-readable)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 90
  $(basename "$0") my-org/my-repo 30 --csv > lead-times.csv

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

# Strip --csv / --json from positional args
args=()
for arg in "$@"; do
  [[ "$arg" != "--csv" && "$arg" != "--json" ]] && args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

resolve_repo "${1:-}" || { usage >&2; exit 1; }
[[ "$_REPO_FROM_ARG" == true ]] && shift

[[ "$JSON" == "true" ]] && json_preflight

# Function to format time in human-readable units
format_time() {
    local seconds=$1
    local hours=$(( seconds / 3600 ))
    
    if (( hours >= 24 )); then
        local days=$(( hours / 24 ))
        printf "%d days" "$days"
    elif (( hours >= 1 )); then
        printf "%d hours" "$hours"
    elif (( seconds >= 60 )); then
        local minutes=$(( seconds / 60 ))
        printf "%d minutes" "$minutes"
    else
        printf "%d seconds" "$seconds"
    fi
}

DAYS="${1:-30}"

# Calculate the cutoff timestamp (ISO 8601) for filtering merged PRs
CUTOFF=$(get_cutoff_date "$DAYS")

if [[ "$CSV" == "false" && "$JSON" == "false" ]]; then
  if [[ -n "${ENG_TEAM:-}" ]]; then
    echo "Fetching PRs merged since $CUTOFF in $REPO (team: $ENG_TEAM) …"
  else
    echo "Fetching PRs merged since $CUTOFF in $REPO …"
  fi
fi
# Fetch up to 1000 merged PRs (adjust --limit if needed), output JSON
if [[ -n "${ENG_TEAM_MEMBERS:-}" ]]; then
  # Per-member queries: divide limit across team members
  IFS=',' read -ra _members <<< "$ENG_TEAM_MEMBERS"
  _member_count=${#_members[@]}
  _per_member_limit=$(( 1000 / _member_count ))
  (( _per_member_limit < 10 )) && _per_member_limit=10

  PR_JSON=""
  for _member in "${_members[@]}"; do
    _member_prs=$(gh pr list \
      --repo "$REPO" \
      --state merged \
      --limit "$_per_member_limit" \
      --author "$_member" \
      --json number,createdAt,mergedAt,author \
      --jq ".[] | select(.mergedAt >= \"$CUTOFF\")" 2>/dev/null || true)
    if [[ -n "$_member_prs" ]]; then
      PR_JSON="${PR_JSON}${PR_JSON:+
}${_member_prs}"
    fi
  done
else
  PR_JSON=$(gh pr list \
    --repo "$REPO" \
    --state merged \
    --limit 1000 \
    --json number,createdAt,mergedAt,author \
    --jq ".[] | select(.mergedAt >= \"$CUTOFF\")")
fi

if [[ -z "$PR_JSON" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "lead-time" "$DAYS" '{"count":0,"avg_seconds":0,"prs":[]}'
    exit 0
  fi
  echo "No PRs merged in the last $DAYS days." >&2
  exit 0
fi

# For each PR, calculate lead time (in hours), accumulate for average
total_seconds=0
count=0

if [[ "$JSON" == "true" ]]; then
  : # collect into pr_records below; no header
elif [[ "$CSV" == "true" ]]; then
  echo "PR,Author,Lead Time,Lead Time (seconds),Created,Merged,URL"
else
  printf "\n%-6s  %-18s  %-15s  %-20s  %-20s  %s\n" "PR#" "Author" "Lead Time" "Created" "Merged" "URL"
  printf "%s\n" "--------------------------------------------------------------------------------------------------------------"
fi

pr_records=()

# Process each PR and store results in arrays
while IFS= read -r pr; do
  num=$(jq -r '.number' <<<"$pr")
  author=$(jq -r '.author.login' <<<"$pr")
  created=$(jq -r '.createdAt' <<<"$pr")
  merged=$(jq -r '.mergedAt' <<<"$pr")

  # parse into Unix seconds
  ts_created=$(parse_timestamp "$created")
  ts_merged=$(parse_timestamp "$merged")
  delta=$(( ts_merged - ts_created ))
  normalized_time=$(format_time "$delta")

  pr_link="https://github.com/$REPO/pull/$num"

  if [[ "$JSON" == "true" ]]; then
    pr_records+=("$(jq -n \
      --argjson number "$num" \
      --arg author "$author" \
      --argjson lead "$delta" \
      --arg created "$created" \
      --arg merged "$merged" \
      --arg url "$pr_link" \
      '{number:$number, author:$author, lead_time_seconds:$lead, created_at:$created, merged_at:$merged, url:$url}')")
  elif [[ "$CSV" == "true" ]]; then
    printf "%s,%s,%s,%s,%s,%s,%s\n" "$num" "$author" "$normalized_time" "$delta" "$created" "$merged" "$pr_link"
  else
    printf "#%-5s  %-18s  %-15s  %-20s  %-20s  %s\n" "$num" "$author" "$normalized_time" "$created" "$merged" "$pr_link"
  fi

  total_seconds=$(( total_seconds + delta ))
  count=$(( count + 1 ))
done <<< "$PR_JSON"

if [[ "$JSON" == "true" ]]; then
  avg_sec=0
  (( count > 0 )) && avg_sec=$(( total_seconds / count ))
  prs_array=$(printf '%s\n' "${pr_records[@]+"${pr_records[@]}"}" | jq -s '.')
  data=$(jq -n \
    --argjson count "$count" \
    --argjson avg "$avg_sec" \
    --argjson prs "$prs_array" \
    '{count:$count, avg_seconds:$avg, prs:$prs}')
  emit_json "lead-time" "$DAYS" "$data"
elif (( count > 0 )) && [[ "$CSV" == "false" ]]; then
  avg_sec=$(( total_seconds / count ))
  avg_time=$(format_time "$avg_sec")
  printf "\nAnalyzed %d PR(s) • Average lead time: %s\n" "$count" "$avg_time"
fi