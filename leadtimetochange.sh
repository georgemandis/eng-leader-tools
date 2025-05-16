#!/usr/bin/env bash
#
# Usage: ./leadtime.sh owner/repo [days]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   days         lookback window in days (default: 30)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#   - numfmt (coreutils)
#

set -euo pipefail

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

REPO="$1"
DAYS="${2:-30}"

# Calculate the cutoff timestamp (ISO 8601) for filtering merged PRs
CUTOFF=$(get_cutoff_date "$DAYS")

echo "Fetching PRs merged since $CUTOFF in $REPO …"
# Fetch up to 1000 merged PRs (adjust --limit if needed), output JSON
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state merged \
  --limit 1000 \
  --json number,createdAt,mergedAt \
  --jq ".[] | select(.mergedAt >= \"$CUTOFF\")")

if [[ -z "$PR_JSON" ]]; then
  echo "No PRs merged in the last $DAYS days."
  exit 0
fi

# For each PR, calculate lead time (in hours), accumulate for average
total_seconds=0
count=0

printf "\nPR#    Lead Time          Created At               Merged At\n"
printf "%s\n" "------------------------------------------------------------"

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

  # Create PR link
  pr_link="https://github.com/$REPO/pull/$num"
  printf "%s %-15s %s   %s\n" "$pr_link" "$normalized_time" "$created" "$merged"

  total_seconds=$(( total_seconds + delta ))
  count=$(( count + 1 ))
done <<< "$PR_JSON"

if (( count > 0 )); then
  avg_sec=$(( total_seconds / count ))
  avg_time=$(format_time "$avg_sec")
  printf "\nAnalyzed %d PR(s) • Average lead time: %s\n" "$count" "$avg_time"
fi