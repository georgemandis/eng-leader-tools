#!/usr/bin/env bash
#
# Change Failure Rate — percentage of merged PRs that are rollbacks or hotfixes.
#
# Usage: ./changefailurerate.sh owner/repo [days]
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

Calculates change failure rate by identifying merged PRs with "rollback"
or "hotfix" in the title as a proportion of all merged PRs.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  days         Lookback window in days (default: 30)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 90

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
else
    # Linux date functions
    get_cutoff_date() {
        local days=$1
        date -u -d "$days days ago" +"%Y-%m-%dT%H:%M:%SZ"
    }
fi

REPO="$1"
DAYS="${2:-30}"

# ISO cutoff timestamp
CUTOFF=$(get_cutoff_date "$DAYS")

echo "Fetching PRs merged since $CUTOFF in $REPO …"

# Fetch merged PRs metadata (number + title) and filter by mergedAt
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state merged \
  --limit 1000 \
  --json number,mergedAt,title \
  --jq "[.[] | select(.mergedAt >= \"$CUTOFF\")]")

if [[ -z "$PR_JSON" ]]; then
  echo "No PRs merged in the last $DAYS days."
  exit 0
fi

# Total count
TOTAL=$(echo "$PR_JSON" | jq 'length')

# Identify "failed" PRs where the title contains rollback or hotfix
FAIL_PR_NUMS=($(echo "$PR_JSON" | jq -r \
  --arg re "(?i)\\b(rollback|hotfix)\\b" \
  '.[] | select(.title | test($re)) | .number'))

FAIL_COUNT=${#FAIL_PR_NUMS[@]}

# Compute percentage
PCT=$(awk "BEGIN { if ($TOTAL > 0) printf \"%.2f\", ($FAIL_COUNT/$TOTAL)*100; else print \"0.00\" }")

# Output
echo
echo "→  Total merged PRs in last $DAYS days: $TOTAL"
echo "→  PRs flagged as failures: $FAIL_COUNT"
echo "→  Change Failure Rate: $PCT%"

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo
  echo "Failed PR numbers:"
  for n in "${FAIL_PR_NUMS[@]}"; do
    echo "  • #$n"
  done
fi