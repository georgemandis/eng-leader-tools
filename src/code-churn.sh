#!/usr/bin/env bash
#
# Code Churn — identifies file hotspots (files changed repeatedly across PRs),
# top churn directories, and risk assessment.
#
# Usage: ./code-churn.sh owner/repo [days] [min_changes]
#   owner/repo     GitHub repo (e.g. "octocat/hello-world")
#   days           lookback window in days (default: 30)
#   min_changes    minimum changes to flag as hotspot (default: 3)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [days] [min_changes]

Identifies file hotspots by analyzing which files are changed most
frequently across merged PRs. Includes directory-level analysis and
risk assessment.

Arguments:
  owner/repo     GitHub repo (e.g. "octocat/hello-world")
  days           Lookback window in days (default: 30)
  min_changes    Minimum changes to flag as hotspot (default: 3)

Options:
  --json         Emit a single JSON envelope (machine-readable) instead of
                 the human-readable table.

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 60 5
  $(basename "$0") my-org/my-repo 30 --json

Requires: gh (authenticated), jq
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Strip the --json flag out of the positional args (this script otherwise
# parses purely positionally).
JSON=false
args=()
for arg in "$@"; do
  case "$arg" in
    --json) JSON=true ;;
    *)      args+=("$arg") ;;
  esac
done
set -- "${args[@]}"

resolve_repo "${1:-}" || { usage >&2; exit 1; }
[[ "$_REPO_FROM_ARG" == true ]] && shift

DAYS="${1:-30}"
MIN_CHANGES="${2:-3}"

[[ "$JSON" == "true" ]] && json_preflight

CUTOFF=$(get_cutoff_date "$DAYS")

[[ "$JSON" == "false" ]] && echo "Analyzing code churn for $REPO (last $DAYS days, min $MIN_CHANGES changes) …"

# Fetch merged PRs since cutoff
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state merged \
  --limit 200 \
  --json number,mergedAt \
  --jq ".[] | select(.mergedAt >= \"$CUTOFF\")")

if [[ -z "$PR_JSON" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "code-churn" "$DAYS" '{"files":[],"hotspot_count":0}'
    exit 0
  fi
  echo "No PRs merged in the last $DAYS days."
  exit 0
fi

# Create temporary file to collect file change data
temp_file=$(mktemp)
trap "rm -f $temp_file" EXIT

pr_count=0

# Process each PR to collect file change information
echo "$PR_JSON" | jq -r '.number' | while read -r num; do
  # Get files changed in this PR
  gh api "repos/$REPO/pulls/$num/files" --paginate | \
    jq -r '.[] | .filename' >> "$temp_file"
  
  pr_count=$((pr_count + 1))
done

if [[ ! -s "$temp_file" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "code-churn" "$DAYS" '{"files":[],"hotspot_count":0}'
    exit 0
  fi
  echo "No file changes found in analyzed PRs."
  exit 0
fi

total_prs=$(echo "$PR_JSON" | jq -s 'length')

hotspots=$(sort "$temp_file" | uniq -c | sort -nr | awk -v min="$MIN_CHANGES" '$1 >= min')

if [[ "$JSON" == "true" ]]; then
  # Build files array from the (already count-desc sorted) hotspots blob.
  # NOTE: this script only collects filenames, not per-file authors, so the
  # `authors` key is intentionally omitted rather than faked.
  if [[ -n "$hotspots" ]]; then
    files_json=$(echo "$hotspots" | awk '{ count=$1; $1=""; sub(/^ /,""); print count "\t" $0 }' | jq -R -s '
      split("\n")
      | map(select(length > 0))
      | map(split("\t") | { path: .[1], change_count: (.[0] | tonumber) })')
    hotspot_count=$(echo "$hotspots" | grep -c '')
  else
    files_json='[]'
    hotspot_count=0
  fi
  data=$(jq -n --argjson files "$files_json" --argjson count "$hotspot_count" \
    '{ files: $files, hotspot_count: $count }')
  emit_json "code-churn" "$DAYS" "$data"
  exit 0
fi

printf "\nCode Churn Analysis:\n"
printf "────────────────────\n"
printf "• Analyzed %d merged PRs\n" "$total_prs"
printf "• Time period: last %d days\n" "$DAYS"
printf "• Flagging files changed ≥%d times\n\n" "$MIN_CHANGES"

# Analyze file change frequency
printf "File Hotspots (files changed multiple times):\n"
printf "──────────────────────────────────────────────\n"
printf "%-6s %s\n" "Times" "File Path"
printf "%s\n" "──────────────────────────────────────────────"

if [[ -n "$hotspots" ]]; then
  echo "$hotspots" | while read -r count filepath; do
    printf "%-6s %s\n" "$count" "$filepath"
  done
  
  hotspot_count=$(echo "$hotspots" | wc -l | tr -d ' ')
  
  echo
  printf "Summary:\n"  
  printf "────────\n"
  printf "• Files identified as hotspots: %d\n" "$hotspot_count"
  
  # Show top churn areas by directory
  echo
  printf "Top Churn Directories:\n"
  printf "─────────────────────\n"
  
  echo "$hotspots" | while read -r count filepath; do
    dirname "$filepath"
  done | sort | uniq -c | sort -nr | head -5 | while read -r dir_count dirname; do
    printf "%-3s changes in %s\n" "$dir_count" "$dirname"
  done
  
  # Risk assessment
  echo
  printf "Risk Assessment:\n"
  printf "────────────────\n"
  
  high_churn_files=$(echo "$hotspots" | awk '$1 >= 5' | wc -l | tr -d ' ')
  
  if (( high_churn_files > 0 )); then
    echo "• 🔴 High risk: $high_churn_files files changed ≥5 times"
    echo "  Consider refactoring or adding tests for stability"
  fi
  
  medium_churn_files=$(echo "$hotspots" | awk '$1 >= 3 && $1 < 5' | wc -l | tr -d ' ')
  
  if (( medium_churn_files > 0 )); then
    echo "• 🟡 Medium risk: $medium_churn_files files changed 3-4 times"
    echo "  Monitor for patterns, may need attention"
  fi
  
  # Show most churned file details
  echo
  most_churned=$(echo "$hotspots" | head -1)
  if [[ -n "$most_churned" ]]; then
    most_count=$(echo "$most_churned" | awk '{print $1}')
    most_file=$(echo "$most_churned" | awk '{$1=""; print $0}' | sed 's/^ *//')
    
    printf "Most Churned File:\n"
    printf "─────────────────\n"
    printf "• %s (%s changes)\n" "$most_file" "$most_count"
    printf "• This file was modified in %.0f%% of analyzed PRs\n" \
      "$(awk "BEGIN { printf \"%.0f\", ($most_count/$total_prs)*100 }")"
  fi
  
else
  echo "• 🟢 No hotspots detected - good code stability!"
  echo "  All files changed fewer than $MIN_CHANGES times"
fi