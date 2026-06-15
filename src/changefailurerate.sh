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

Options:
  --csv        Output failed PRs as CSV instead of narrative summary
  --json       Output as a single JSON envelope (machine-readable)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 90
  $(basename "$0") my-org/my-repo 30 --csv > failures.csv

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

# Strip --csv and --json from positional args
args=()
for arg in "$@"; do
  [[ "$arg" != "--csv" && "$arg" != "--json" ]] && args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

resolve_repo "${1:-}" || { usage >&2; exit 1; }
[[ "$_REPO_FROM_ARG" == true ]] && shift

[[ "$JSON" == "true" ]] && json_preflight

DAYS="${1:-30}"

# ISO cutoff timestamp
CUTOFF=$(get_cutoff_date "$DAYS")

[[ "$JSON" == "false" ]] && echo "Fetching PRs merged since $CUTOFF in $REPO …"

# Fetch merged PRs metadata (number + title) and filter by mergedAt
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state merged \
  --limit 1000 \
  --json number,mergedAt,title \
  --jq "[.[] | select(.mergedAt >= \"$CUTOFF\")]")

if [[ -z "$PR_JSON" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "change-failure-rate" "$DAYS" \
      '{"total_merged":0,"failure_count":0,"failure_rate":0,"failures":[]}'
    exit 0
  fi
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
if [[ "$JSON" == "true" ]]; then
  data=$(echo "$PR_JSON" | jq \
    --arg repo "$REPO" \
    --arg re "(?i)\\b(rollback|hotfix)\\b" '
    (map(select(.title | test($re)))) as $fails
    | (length) as $total
    | ($fails | length) as $fc
    | {
        total_merged: $total,
        failure_count: $fc,
        failure_rate: (if $total > 0 then ($fc / $total) else 0 end),
        failures: ($fails | map({
          number: .number,
          reason: (if (.title | test("(?i)\\bhotfix\\b")) then "hotfix" else "rollback" end),
          url: ("https://github.com/" + $repo + "/pull/" + (.number | tostring))
        }))
      }')
  emit_json "change-failure-rate" "$DAYS" "$data"
  exit 0
fi

if [[ "$CSV" == "true" ]]; then
  echo "PR,Title,URL"
  for n in "${FAIL_PR_NUMS[@]}"; do
    csv_title=$(echo "$PR_JSON" | jq -r --argjson num "$n" '.[] | select(.number == $num) | .title' | sed 's/"/""/g')
    printf "%s,\"%s\",%s\n" "$n" "$csv_title" "https://github.com/$REPO/pull/$n"
  done
  exit 0
fi

echo
echo "→  Total merged PRs in last $DAYS days: $TOTAL"
echo "→  PRs flagged as failures: $FAIL_COUNT"
echo "→  Change Failure Rate: $PCT%"

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo
  echo "Failed PRs:"
  for n in "${FAIL_PR_NUMS[@]}"; do
    echo "  • #$n — https://github.com/$REPO/pull/$n"
  done
fi