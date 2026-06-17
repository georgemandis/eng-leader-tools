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
  --json       Output as a single JSON envelope (machine-readable)

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

COUNT="${1:-50}"

if [[ "$CSV" == "false" && "$JSON" == "false" ]]; then
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
  if [[ "$JSON" == "true" ]]; then
    emit_json "review-load" null '{"total_reviews":0,"reviewers":[],"top_share":0}'
    exit 0
  fi
  echo "No merged PRs found."
  exit 0
fi

# Temp files for collecting data
temp_reviews=$(mktemp)
temp_authors=$(mktemp)
trap "rm -f $temp_reviews $temp_authors" EXIT

# Authors: one line per PR (in PR_JSON order), filtered to team members when a
# team filter is set. This needs no gh call, so derive it directly from PR_JSON
# rather than looping — matches the serial behavior exactly.
if [[ -z "$_team_filter" ]]; then
  echo "$PR_JSON" | jq -r '.[].author.login' >> "$temp_authors"
else
  echo "$PR_JSON" | jq -r '.[].author.login' \
    | grep -E "^(${_team_filter})$" >> "$temp_authors" || true
fi

# Worker: input is "<number>|<author>"; fetches that PR's reviews and emits
# "<login> <state>" lines (excluding the PR author), applying the team filter
# exactly as the serial version did.
_rl_fetch_reviews() {
  local num="${1%%|*}" author="${1#*|}"
  local reviews
  reviews=$(gh api "repos/$REPO/pulls/$num/reviews" --paginate 2>/dev/null || echo "[]")

  if [[ -n "$_RL_TEAM_FILTER" ]]; then
    echo "$reviews" | jq -r --arg author "$author" \
      '.[] | select(.user.login != $author) | "\(.user.login) \(.state)"' \
      | grep -E "^(${_RL_TEAM_FILTER}) " || true
  else
    echo "$reviews" | jq -r --arg author "$author" \
      '.[] | select(.user.login != $author) | "\(.user.login) \(.state)"'
  fi
}
export REPO
export _RL_TEAM_FILTER="$_team_filter"

# Run all per-PR review fetches in parallel; collect into the temp file.
echo "$PR_JSON" \
  | jq -r '.[] | "\(.number)|\(.author.login)"' \
  | parallel_map _rl_fetch_reviews >> "$temp_reviews"

if [[ ! -s "$temp_reviews" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "review-load" null '{"total_reviews":0,"reviewers":[],"top_share":0}'
    exit 0
  fi
  echo "No reviews found in analyzed PRs."
  exit 0
fi

total_prs=$(wc -l < "$temp_authors" | tr -d ' ')

if [[ "$JSON" == "true" ]]; then
  # Build the reviewer tally with a dedicated jq pass over the collected
  # data (temp_reviews survives the per-PR subshell). Each line is
  # "<login> <state>"; count one review per line.
  data=$(awk '{print $1}' "$temp_reviews" | jq -R . | jq -s '
    (length) as $total
    | (group_by(.) | map({login: .[0], reviews: length})
       | sort_by(.reviews) | reverse) as $r
    | {
        total_reviews: $total,
        reviewers: ($r | map({
          login: .login,
          reviews: .reviews,
          share: (if $total > 0 then (.reviews / $total) else 0 end)
        })),
        top_share: (if ($r | length) > 0 and $total > 0
                    then ($r[0].reviews / $total) else 0 end)
      }')
  emit_json "review-load" null "$data"
  exit 0
fi

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
