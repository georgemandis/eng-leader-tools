#!/usr/bin/env bash
#
# PR Review Time — measures time to first review and time to merge,
# with process health indicators for review coverage and responsiveness.
#
# Usage: ./pr-review-time.sh owner/repo [count]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   count        number of recent merged PRs to analyze (default: 30)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [count]

Analyzes PR review times: time to first review, time to merge, review
coverage, and responsiveness. Makes one API call per PR for review data.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  count        Number of recent merged PRs to analyze (default: 30)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 50

Requires: gh (authenticated), jq
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Resolve repo: explicit arg (must contain /) > ENG_REPO env var
if [[ -n "${1:-}" && "$1" == */* ]]; then
  REPO="$1"
  shift
elif [[ -n "${ENG_REPO:-}" ]]; then
  REPO="$ENG_REPO"
else
  echo "Error: missing required argument owner/repo (not in a GitHub repo)" >&2
  usage >&2
  exit 1
fi

# Detect OS and set appropriate date functions
if [[ "$OSTYPE" == "darwin"* ]]; then
    parse_timestamp() {
        local timestamp=$1
        date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s
    }
else
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
        printf "%dd" "$days"
    elif (( hours >= 1 )); then
        printf "%dh" "$hours"
    elif (( seconds >= 60 )); then
        local minutes=$(( seconds / 60 ))
        printf "%dm" "$minutes"
    else
        printf "%ds" "$seconds"
    fi
}

COUNT="${1:-30}"

if [[ -n "${ENG_TEAM:-}" ]]; then
  echo "Analyzing PR review times for $REPO (last $COUNT merged PRs, team: $ENG_TEAM) …"
else
  echo "Analyzing PR review times for $REPO (last $COUNT merged PRs) …"
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
      --json number,createdAt,mergedAt,author,url 2>/dev/null || echo "[]")
    _all_prs=$(jq -s 'add' <(echo "$_all_prs") <(echo "$_member_prs"))
  done
  PR_JSON=$(echo "$_all_prs" | jq --argjson n "$COUNT" 'unique_by(.number) | sort_by(.mergedAt) | reverse | .[:$n]')
else
  PR_JSON=$(gh pr list \
    --repo "$REPO" \
    --state merged \
    --limit "$COUNT" \
    --json number,createdAt,mergedAt,author,url)
fi

if [[ -z "$PR_JSON" ]] || [[ "$PR_JSON" == "[]" ]]; then
  echo "No merged PRs found."
  exit 0
fi

total_first_review_time=0
total_merge_time=0
total_prs_with_reviews=0
total_prs=0

printf "\nPR Review Analysis:\n"
printf "──────────────────\n"
printf "%-6s %-8s %-8s %-8s %-18s %s\n" "PR#" "1st Rev" "Merge" "Reviews" "Author" "URL"
printf "%s\n" "──────────────────────────────────────────────────────────────────────────────────────"

# Process each PR
echo "$PR_JSON" | jq -r '.[] | @base64' | while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)
  
  num=$(echo "$pr" | jq -r '.number')
  created=$(echo "$pr" | jq -r '.createdAt')
  merged=$(echo "$pr" | jq -r '.mergedAt')
  author=$(echo "$pr" | jq -r '.author.login')
  url=$(echo "$pr" | jq -r '.url')

  # Get review information
  reviews=$(gh api "repos/$REPO/pulls/$num/reviews" --paginate)
  review_count=$(echo "$reviews" | jq 'length')
  
  # Calculate times
  ts_created=$(parse_timestamp "$created")
  ts_merged=$(parse_timestamp "$merged")
  merge_delta=$(( ts_merged - ts_created ))
  merge_time=$(format_time "$merge_delta")
  
  if (( review_count > 0 )); then
    first_review_date=$(echo "$reviews" | jq -r 'min_by(.submitted_at) | .submitted_at')
    ts_first_review=$(parse_timestamp "$first_review_date")
    first_review_delta=$(( ts_first_review - ts_created ))
    first_review_time=$(format_time "$first_review_delta")
    
    total_first_review_time=$((total_first_review_time + first_review_delta))
    total_prs_with_reviews=$((total_prs_with_reviews + 1))
  else
    first_review_time="N/A"
  fi
  
  printf "#%-5s %-8s %-8s %-8s %-18s %s\n" "$num" "$first_review_time" "$merge_time" "$review_count" "$author" "$url"
  
  total_merge_time=$((total_merge_time + merge_delta))
  total_prs=$((total_prs + 1))
done

if (( total_prs > 0 )); then
  avg_merge_time=$(( total_merge_time / total_prs ))
  avg_merge_formatted=$(format_time "$avg_merge_time")
  
  echo
  printf "Summary:\n"
  printf "────────\n"
  printf "• Total PRs analyzed: %d\n" "$total_prs"
  printf "• Average time to merge: %s\n" "$avg_merge_formatted"
  
  if (( total_prs_with_reviews > 0 )); then
    avg_first_review_time=$(( total_first_review_time / total_prs_with_reviews ))
    avg_first_review_formatted=$(format_time "$avg_first_review_time")
    printf "• Average time to first review: %s\n" "$avg_first_review_formatted"
    printf "• PRs with reviews: %d/%d (%.0f%%)\n" \
      "$total_prs_with_reviews" "$total_prs" \
      "$(awk "BEGIN { printf \"%.0f\", ($total_prs_with_reviews/$total_prs)*100 }")"
  fi
  
  # Review process health indicators
  echo
  printf "Process Health:\n"
  printf "───────────────\n"
  
  review_rate=$(awk "BEGIN { printf \"%.0f\", ($total_prs_with_reviews/$total_prs)*100 }")
  
  if (( review_rate >= 90 )); then
    echo "• 🟢 Review coverage: Excellent (${review_rate}%)"
  elif (( review_rate >= 70 )); then
    echo "• 🟡 Review coverage: Good (${review_rate}%)"
  else
    echo "• 🔴 Review coverage: Needs improvement (${review_rate}%)"
  fi
  
  if (( total_prs_with_reviews > 0 )); then
    avg_hours=$(( avg_first_review_time / 3600 ))
    
    if (( avg_hours <= 4 )); then
      echo "• 🟢 Review responsiveness: Excellent (${avg_first_review_formatted} avg)"
    elif (( avg_hours <= 24 )); then
      echo "• 🟡 Review responsiveness: Good (${avg_first_review_formatted} avg)"
    else
      echo "• 🔴 Review responsiveness: Slow (${avg_first_review_formatted} avg)"
    fi
  fi
fi