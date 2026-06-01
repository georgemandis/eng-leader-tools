#!/usr/bin/env bash
#
# Contributor File Patterns — shows per-contributor PR size patterns,
# identifying focused (small PRs) vs. broad-scope (large PRs) contributors.
#
# Usage: ./contributor-file-patterns.sh owner/repo [count]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   count        number of recent merged PRs to analyze (default: 50)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [count]

Analyzes file change patterns per contributor across recent merged PRs.
Shows PR count, total/average/max files changed per author, and identifies
focused (<3 files avg) vs. broad-scope (>10 files avg) contributors.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  count        Number of recent merged PRs to analyze (default: 50)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 100

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

COUNT="${1:-50}"

if [[ -n "${ENG_TEAM:-}" ]]; then
  echo "Analyzing file change patterns for contributors in $REPO (last $COUNT PRs, team: $ENG_TEAM) …"
else
  echo "Analyzing file change patterns for contributors in $REPO (last $COUNT PRs) …"
fi

# Fetch recent merged PRs with author info
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

# Temporary file to collect data
temp_file=$(mktemp)
trap "rm -f $temp_file" EXIT

# Process each PR to collect contributor and file count data
echo "$PR_JSON" | jq -r '.[] | @base64' | while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)
  
  num=$(echo "$pr" | jq -r '.number')
  author=$(echo "$pr" | jq -r '.author.login')

  # Skip non-team members if team filter is active
  if [[ -n "${ENG_TEAM_MEMBERS:-}" ]]; then
    if ! echo ",${ENG_TEAM_MEMBERS}," | grep -q ",${author},"; then
      continue
    fi
  fi

  # Get file count for this PR
  files_count=$(gh api "repos/$REPO/pulls/$num/files" --paginate | jq 'length')
  
  echo "$author $files_count" >> "$temp_file"
done

# Aggregate data by contributor
printf "\nContributor File Change Patterns:\n"
printf "%-20s %5s %5s %5s %5s\n" "Author" "PRs" "Total" "Avg" "Max"
printf "%s\n" "──────────────────────────────────────────────────────────"

# Group by author and calculate stats
sort "$temp_file" | awk '
{
  author = $1
  files = $2
  
  count[author]++
  total[author] += files
  
  if (files > max[author]) {
    max[author] = files
  }
}
END {
  for (author in count) {
    avg = total[author] / count[author]
    printf "%-20s %5d %5d %5.1f %5d\n", author, count[author], total[author], avg, max[author]
  }
}' | sort -k3 -nr

echo

# Identify patterns
printf "Pattern Analysis:\n"
printf "─────────────────\n"

# Contributors with consistently small changes (avg < 3 files)
small_change_contributors=$(sort "$temp_file" | awk '
{
  author = $1
  files = $2
  
  count[author]++
  total[author] += files
}
END {
  for (author in count) {
    if (count[author] >= 3) {
      avg = total[author] / count[author]
      if (avg < 3) {
        print author " (" avg ")"
      }
    }
  }
}' | head -5)

if [[ -n "$small_change_contributors" ]]; then
  echo "• Focused contributors (avg <3 files/PR):"
  echo "$small_change_contributors" | while read -r line; do
    echo "  - $line"
  done
  echo
fi

# Contributors with large changes (avg > 10 files)
large_change_contributors=$(sort "$temp_file" | awk '
{
  author = $1
  files = $2
  
  count[author]++
  total[author] += files
}
END {
  for (author in count) {
    if (count[author] >= 2) {
      avg = total[author] / count[author]
      if (avg > 10) {
        print author " (" avg ")"
      }
    }
  }
}' | head -5)

if [[ -n "$large_change_contributors" ]]; then
  echo "• Broad-scope contributors (avg >10 files/PR):"
  echo "$large_change_contributors" | while read -r line; do
    echo "  - $line"
  done
fi