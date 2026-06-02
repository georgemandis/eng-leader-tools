#!/usr/bin/env bash
#
# Review Load — shows how review work is distributed across team members
# for recent merged PRs.
#
# Usage: ./review-load.sh owner/repo [count]
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [count]

Shows how code review work is distributed across team members. Analyzes
recent merged PRs to tally reviews given per person, highlighting
imbalances in review load.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  count        Number of recent merged PRs to analyze (default: 50)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 100
  $(basename "$0") my-org/my-repo --csv > review-load.csv

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

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

resolve_repo "${1:-}" || { usage >&2; exit 1; }
[[ "$_REPO_FROM_ARG" == true ]] && shift

COUNT="${1:-50}"

if [[ "$CSV" == "false" ]]; then
  if [[ -n "${ENG_TEAM:-}" ]]; then
    echo "Analyzing review load for $REPO (last $COUNT merged PRs, team: $ENG_TEAM) …"
  else
    echo "Analyzing review load for $REPO (last $COUNT merged PRs) …"
  fi
fi

# Build team member filter for grep
_team_filter=""
if [[ -n "${ENG_TEAM_MEMBERS:-}" ]]; then
  IFS=',' read -ra _members <<< "$ENG_TEAM_MEMBERS"
  for _m in "${_members[@]}"; do
    _team_filter="${_team_filter}${_team_filter:+|}${_m}"
  done
fi

# Fetch recent merged PRs
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
  echo "No merged PRs found."
  exit 0
fi

# Temp files for collecting data
temp_reviews=$(mktemp)
temp_authors=$(mktemp)
trap "rm -f $temp_reviews $temp_authors" EXIT

total_prs=0

# Process each PR to collect reviewer data
echo "$PR_JSON" | jq -r '.[] | @base64' | while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)

  num=$(echo "$pr" | jq -r '.number')
  author=$(echo "$pr" | jq -r '.author.login')

  if [[ -z "$_team_filter" ]] || echo "$author" | grep -qE "^(${_team_filter})$"; then
    echo "$author" >> "$temp_authors"
  fi

  # Get reviews for this PR
  reviews=$(gh api "repos/$REPO/pulls/$num/reviews" --paginate 2>/dev/null || echo "[]")

  # Extract unique reviewers (excluding the PR author) and their decisions
  if [[ -n "$_team_filter" ]]; then
    echo "$reviews" | jq -r --arg author "$author" \
      '.[] | select(.user.login != $author) | "\(.user.login) \(.state)"' \
      | grep -E "^(${_team_filter}) " >> "$temp_reviews" || true
  else
    echo "$reviews" | jq -r --arg author "$author" \
      '.[] | select(.user.login != $author) | "\(.user.login) \(.state)"' >> "$temp_reviews"
  fi

  total_prs=$((total_prs + 1))
done

if [[ ! -s "$temp_reviews" ]]; then
  echo "No reviews found in analyzed PRs."
  exit 0
fi

total_prs=$(wc -l < "$temp_authors" | tr -d ' ')

if [[ "$CSV" == "true" ]]; then
  echo "Reviewer,Total,Approved,Changes Requested,Comments"
  awk '
  {
    reviewer = $1
    state = $2
    total[reviewer]++
    if (state == "APPROVED") approved[reviewer]++
    else if (state == "CHANGES_REQUESTED") changes[reviewer]++
    else if (state == "COMMENTED") commented[reviewer]++
  }
  END {
    for (r in total) {
      printf "%s,%d,%d,%d,%d\n", r, total[r], approved[r]+0, changes[r]+0, commented[r]+0
    }
  }' "$temp_reviews" | sort -t, -k2 -nr
  exit 0
fi

printf "\nReview Load Distribution:\n"
printf "─────────────────────────\n"
printf "%-20s  %6s  %8s  %8s  %8s\n" "Reviewer" "Total" "Approved" "Changes" "Comments"
printf "%s\n" "────────────────────────────────────────────────────────────────"

# Aggregate by reviewer
awk '
{
  reviewer = $1
  state = $2
  total[reviewer]++
  if (state == "APPROVED") approved[reviewer]++
  else if (state == "CHANGES_REQUESTED") changes[reviewer]++
  else if (state == "COMMENTED") commented[reviewer]++
}
END {
  for (r in total) {
    printf "%-20s  %6d  %8d  %8d  %8d\n", r, total[r], approved[r]+0, changes[r]+0, commented[r]+0
  }
}' "$temp_reviews" | sort -k2 -nr

# Summary stats
total_reviews=$(wc -l < "$temp_reviews" | tr -d ' ')
unique_reviewers=$(awk '{print $1}' "$temp_reviews" | sort -u | wc -l | tr -d ' ')
unique_authors=$(sort -u "$temp_authors" | wc -l | tr -d ' ')

echo
printf "Summary:\n"
printf "────────\n"
printf "  PRs analyzed:      %d\n" "$total_prs"
printf "  Total reviews:     %d\n" "$total_reviews"
printf "  Unique reviewers:  %d\n" "$unique_reviewers"
printf "  Unique authors:    %d\n" "$unique_authors"

if (( total_reviews > 0 && total_prs > 0 )); then
  avg_reviews=$(awk "BEGIN { printf \"%.1f\", $total_reviews/$total_prs }")
  printf "  Avg reviews/PR:    %s\n" "$avg_reviews"
fi

# Load balance assessment
if (( unique_reviewers >= 2 )); then
  top_reviewer_count=$(awk '{print $1}' "$temp_reviews" | sort | uniq -c | sort -nr | head -1 | awk '{print $1}')
  top_reviewer_name=$(awk '{print $1}' "$temp_reviews" | sort | uniq -c | sort -nr | head -1 | awk '{print $2}')
  top_pct=$(awk "BEGIN { printf \"%.0f\", ($top_reviewer_count/$total_reviews)*100 }")

  echo
  printf "Load Balance:\n"
  printf "─────────────\n"

  if (( top_pct >= 50 )); then
    printf "  %s is handling %s%% of all reviews — consider redistributing.\n" "$top_reviewer_name" "$top_pct"
  elif (( top_pct >= 35 )); then
    printf "  Review load is somewhat concentrated (%s at %s%%).\n" "$top_reviewer_name" "$top_pct"
  else
    printf "  Review load is well distributed (top reviewer: %s%%).\n" "$top_pct"
  fi

  # Check for authors who never review
  authors_who_review=$(comm -12 <(sort -u "$temp_authors") <(awk '{print $1}' "$temp_reviews" | sort -u) | wc -l | tr -d ' ')
  authors_not_reviewing=$(( unique_authors - authors_who_review ))

  if (( authors_not_reviewing > 0 )); then
    printf "  %d contributor(s) authored PRs but gave no reviews.\n" "$authors_not_reviewing"
  fi
fi
