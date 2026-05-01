#!/usr/bin/env bash
#
# Lead Time to Change (per user) — measures average time from PR creation
# to merge for a specific contributor.
#
# Usage: ./leadtimetochange-user.sh owner/repo username [days]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   username     GitHub username to filter PRs by
#   days         lookback window in days (default: 30)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo username [days]

Measures average lead time from PR creation to merge for a specific user.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  username     GitHub username to filter PRs by
  days         Lookback window in days (default: 30)

Examples:
  $(basename "$0") my-org/my-repo janedoe
  $(basename "$0") my-org/my-repo janedoe 60
  $(basename "$0") my-org/my-repo janedoe --csv > lead-times.csv

Options:
  --csv        Output as CSV instead of formatted table

Requires: gh (authenticated), jq
EOF
}

CSV=false
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --csv) CSV=true ;;
  esac
done

# Strip --csv from positional args
args=()
for arg in "$@"; do
  [[ "$arg" != "--csv" ]] && args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

# Detect OS and set appropriate date functions
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS date functions
    get_cutoff_date() {
        local days=$1
        date -u -v-"$days"d +"%Y-%m-%dT%H:%M:%SZ"
    }

    parse_timestamp() {
        local timestamp=$1
        date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s
    }
else
    # Linux date functions
    get_cutoff_date() {
        local days=$1
        date -u -d "$days days ago" +"%Y-%m-%dT%H:%M:%SZ"
    }

    parse_timestamp() {
        local timestamp=$1
        date -d "$timestamp" +%s
    }
fi

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

# Check required arguments
if [[ $# -lt 2 ]]; then
    echo "Error: missing required arguments" >&2
    usage >&2
    exit 1
fi

REPO="$1"
USERNAME="$2"
DAYS="${3:-30}"

# Calculate the cutoff timestamp (ISO 8601) for filtering merged PRs
CUTOFF=$(get_cutoff_date "$DAYS")

[[ "$CSV" == "false" ]] && echo "Fetching PRs by @$USERNAME merged since $CUTOFF in $REPO …"
# Fetch up to 1000 merged PRs (adjust --limit if needed), output JSON
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state merged \
  --limit 1000 \
  --author "$USERNAME" \
  --json number,createdAt,mergedAt,author \
  --jq ".[] | select(.mergedAt >= \"$CUTOFF\")")

if [[ -z "$PR_JSON" ]]; then
  echo "No PRs by @$USERNAME merged in the last $DAYS days." >&2
  exit 0
fi

# For each PR, calculate lead time (in hours), accumulate for average
total_seconds=0
count=0

if [[ "$CSV" == "true" ]]; then
  echo "PR,Lead Time,Lead Time (seconds),Created,Merged,URL"
else
  printf "\n%-6s  %-15s  %-20s  %-20s  %s\n" "PR#" "Lead Time" "Created" "Merged" "URL"
  printf "%s\n" "-----------------------------------------------------------------------------------------------"
fi

# Process each PR and store results in arrays
while IFS= read -r pr; do
  num=$(jq -r '.number' <<<"$pr")
  created=$(jq -r '.createdAt' <<<"$pr")
  merged=$(jq -r '.mergedAt' <<<"$pr")

  # parse into Unix seconds
  ts_created=$(parse_timestamp "$created")
  ts_merged=$(parse_timestamp "$merged")
  delta=$(( ts_merged - ts_created ))
  normalized_time=$(format_time "$delta")

  pr_link="https://github.com/$REPO/pull/$num"

  if [[ "$CSV" == "true" ]]; then
    printf "%s,%s,%s,%s,%s,%s\n" "$num" "$normalized_time" "$delta" "$created" "$merged" "$pr_link"
  else
    printf "#%-5s  %-15s  %-20s  %-20s  %s\n" "$num" "$normalized_time" "$created" "$merged" "$pr_link"
  fi

  total_seconds=$(( total_seconds + delta ))
  count=$(( count + 1 ))
done <<< "$PR_JSON"

if (( count > 0 )) && [[ "$CSV" == "false" ]]; then
  avg_sec=$(( total_seconds / count ))
  avg_time=$(format_time "$avg_sec")
  printf "\nAnalyzed %d PR(s) by @%s • Average lead time: %s\n" "$count" "$USERNAME" "$avg_time"
fi