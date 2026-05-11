#!/usr/bin/env bash
#
# Deployment Frequency — how often releases or tags ship, with DORA tier assessment.
#
# Usage: ./deployment-frequency.sh owner/repo [days]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   days         lookback window in days (default: 90)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [days]

Analyzes deployment frequency using GitHub releases and tags. Includes
a DORA performance tier assessment (Elite/High/Medium/Low).

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  days         Lookback window in days (default: 90)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 180

Requires: gh (authenticated), jq
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "Error: missing required argument owner/repo" >&2
  usage >&2
  exit 1
fi

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
    
    format_date() {
        local timestamp=$1
        date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +"%Y-%m-%d"
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
    
    format_date() {
        local timestamp=$1
        date -d "$timestamp" +"%Y-%m-%d"
    }
fi

# Function to format time in human-readable units
format_time_diff() {
    local seconds=$1
    local days=$(( seconds / 86400 ))
    
    if (( days >= 1 )); then
        printf "%d days" "$days"
    else
        local hours=$(( seconds / 3600 ))
        printf "%d hours" "$hours"
    fi
}

REPO="$1"
DAYS="${2:-90}"

CUTOFF=$(get_cutoff_date "$DAYS")

echo "Analyzing deployment frequency for $REPO (last $DAYS days) …"

# Fetch releases/tags since cutoff
RELEASES_JSON=$(gh api "repos/$REPO/releases" --paginate | \
  jq --arg cutoff "$CUTOFF" '[.[] | select(.published_at >= $cutoff)]')

# Also fetch tags in case releases aren't used
TAGS_JSON=$(gh api "repos/$REPO/tags" --paginate | \
  jq --arg cutoff "$CUTOFF" '[.[] | select(.commit.commit.author.date >= $cutoff)]')

release_count=$(echo "$RELEASES_JSON" | jq 'length')
tag_count=$(echo "$TAGS_JSON" | jq 'length')

printf "\nDeployment Activity:\n"
printf "────────────────────\n"
printf "• Releases in last %d days: %d\n" "$DAYS" "$release_count"
printf "• Tags in last %d days: %d\n" "$DAYS" "$tag_count"

# Use releases if available, otherwise fall back to tags
if (( release_count > 0 )); then
  deployments="$RELEASES_JSON"
  deployment_type="releases"
  date_field=".published_at"
  name_field=".tag_name"
else
  deployments="$TAGS_JSON"
  deployment_type="tags"
  date_field=".commit.commit.author.date"
  name_field=".name"
fi

deployment_count=$(echo "$deployments" | jq 'length')

if (( deployment_count == 0 )); then
  echo "• No deployments found in the specified period"
  exit 0
fi

printf "• Using %s for analysis\n\n" "$deployment_type"

# Calculate frequency
if (( deployment_count > 1 )); then
  avg_days=$(awk "BEGIN { printf \"%.1f\", $DAYS/$deployment_count }")
  printf "Average deployment frequency: Every %s days\n\n" "$avg_days"
fi

# Show recent deployments
printf "Recent Deployments:\n"
printf "───────────────────\n"
printf "%-12s %-20s %s\n" "Date" "Version" "Time Since Previous"
printf "%s\n" "────────────────────────────────────────────────────────"

# Sort deployments by date (most recent first) and calculate intervals
echo "$deployments" | jq -r "sort_by($date_field) | reverse | .[] | [$date_field, $name_field] | @tsv" | \
while IFS=$'\t' read -r timestamp name; do
  formatted_date=$(format_date "$timestamp")
  
  # Calculate time since previous deployment
  if [[ -n "${prev_timestamp:-}" ]]; then
    current_ts=$(parse_timestamp "$timestamp")
    prev_ts=$(parse_timestamp "$prev_timestamp")
    diff_seconds=$(( prev_ts - current_ts ))
    time_diff=$(format_time_diff "$diff_seconds")
  else
    time_diff="(most recent)"
  fi
  
  printf "%-12s %-20s %s\n" "$formatted_date" "$name" "$time_diff"
  prev_timestamp="$timestamp"
done

# DORA metrics assessment
echo
printf "DORA Assessment:\n"
printf "────────────────\n"

if (( deployment_count >= DAYS )); then
  echo "• 🟢 Elite: On-demand deployments (multiple per day)"
elif (( deployment_count >= DAYS/7 )); then
  echo "• 🟡 High: Weekly deployments"
elif (( deployment_count >= 1 )); then
  echo "• 🟠 Medium: Monthly deployments"
else
  echo "• 🔴 Low: Less than monthly deployments"
fi