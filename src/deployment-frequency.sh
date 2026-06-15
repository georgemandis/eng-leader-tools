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

Options:
  --csv        Output as CSV instead of formatted table
  --json       Output as a single JSON envelope (machine-readable)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 180
  $(basename "$0") my-org/my-repo 180 --csv > deployments.csv

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

DAYS="${1:-90}"

CUTOFF=$(get_cutoff_date "$DAYS")

[[ "$CSV" == "false" && "$JSON" == "false" ]] && echo "Analyzing deployment frequency for $REPO (last $DAYS days) …"

# Fetch releases/tags since cutoff
RELEASES_JSON=$(gh api "repos/$REPO/releases" --paginate | \
  jq --arg cutoff "$CUTOFF" '[.[] | select(.published_at >= $cutoff)]')

# Also fetch tags in case releases aren't used
TAGS_JSON=$(gh api "repos/$REPO/tags" --paginate | \
  jq --arg cutoff "$CUTOFF" '[.[] | select(.commit.commit.author.date >= $cutoff)]')

release_count=$(echo "$RELEASES_JSON" | jq 'length')
tag_count=$(echo "$TAGS_JSON" | jq 'length')

if [[ "$CSV" == "false" && "$JSON" == "false" ]]; then
  printf "\nDeployment Activity:\n"
  printf "────────────────────\n"
  printf "• Releases in last %d days: %d\n" "$DAYS" "$release_count"
  printf "• Tags in last %d days: %d\n" "$DAYS" "$tag_count"
fi

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
  if [[ "$JSON" == "true" ]]; then
    data=$(jq -n --argjson window "$DAYS" \
      '{ window_days: $window, deploy_count: 0, deploys_per_day: 0, series: [] }')
    emit_json "deploy-frequency" "$DAYS" "$data"
    exit 0
  fi
  echo "• No deployments found in the specified period"
  exit 0
fi

# JSON output wins over CSV: emit one envelope and exit before any table/CSV output.
if [[ "$JSON" == "true" ]]; then
  data=$(echo "$deployments" | jq \
    --arg datefield "$date_field" \
    --argjson window "$DAYS" \
    '
    ( [ .[] | getpath($datefield | ltrimstr(".") | split(".")) | .[0:10] ]
      | group_by(.)
      | map({ date: .[0], count: length })
      | sort_by(.date) ) as $series
    | ($series | map(.count) | add // 0) as $count
    | {
        window_days: $window,
        deploy_count: $count,
        deploys_per_day: (if $window == 0 then 0 else (($count / $window) * 100 | round / 100) end),
        series: $series
      }
    ')
  emit_json "deploy-frequency" "$DAYS" "$data"
  exit 0
fi

if [[ "$CSV" == "false" ]]; then
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
else
  echo "Date,Version,TimeSincePrevious"
fi

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

  if [[ "$CSV" == "true" ]]; then
    printf "%s,%s,%s\n" "$formatted_date" "$name" "$time_diff"
  else
    printf "%-12s %-20s %s\n" "$formatted_date" "$name" "$time_diff"
  fi
  prev_timestamp="$timestamp"
done

[[ "$CSV" == "true" ]] && exit 0

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