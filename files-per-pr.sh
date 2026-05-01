#!/usr/bin/env bash
#
# Files Per PR — shows how many files each recent merged PR touched.
#
# Usage: ./files-per-pr.sh owner/repo [count]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   count        number of recent merged PRs to analyze (default: 20)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [count]

Lists files changed per recent merged PR with author and title.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  count        Number of recent merged PRs to analyze (default: 20)

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

if [[ $# -lt 1 ]]; then
  echo "Error: missing required argument owner/repo" >&2
  usage >&2
  exit 1
fi

REPO="$1"
COUNT="${2:-20}"

echo "Fetching last $COUNT merged PRs from $REPO …"

# Fetch recent merged PRs with basic info
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state merged \
  --limit "$COUNT" \
  --json number,title,mergedAt,author,url)

if [[ -z "$PR_JSON" ]] || [[ "$PR_JSON" == "[]" ]]; then
  echo "No merged PRs found."
  exit 0
fi

total_files=0
total_prs=0

printf "\n%-6s %-6s %-18s %-40s %s\n" "PR#" "Files" "Author" "Title" "URL"
printf "%s\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────"

# Process each PR to get file count
echo "$PR_JSON" | jq -r '.[] | @base64' | while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)
  
  num=$(echo "$pr" | jq -r '.number')
  title=$(echo "$pr" | jq -r '.title')
  author=$(echo "$pr" | jq -r '.author.login')
  url=$(echo "$pr" | jq -r '.url')

  # Fetch files for this PR
  files_count=$(gh api "repos/$REPO/pulls/$num/files" --paginate | jq 'length')
  
  # Truncate title if too long
  truncated_title=$(echo "$title" | cut -c1-40)
  if [[ ${#title} -gt 40 ]]; then
    truncated_title="${truncated_title}…"
  fi
  
  printf "#%-5s %-5s %-18s %-40s %s\n" "$num" "$files_count" "$author" "$truncated_title" "$url"
  
  total_files=$((total_files + files_count))
  total_prs=$((total_prs + 1))
done

if (( total_prs > 0 )); then
  avg_files=$(awk "BEGIN { printf \"%.1f\", $total_files/$total_prs }")
  printf "\nAnalyzed %d PRs • Total files changed: %d • Average: %s files/PR\n" \
    "$total_prs" "$total_files" "$avg_files"
fi