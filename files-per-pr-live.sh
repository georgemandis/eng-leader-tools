#!/usr/bin/env bash
#
# Usage: ./files-per-pr-live.sh owner/repo [count]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   count        number of open PRs to analyze (default: 20)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

REPO="$1"
COUNT="${2:-20}"

echo "Fetching up to $COUNT open PRs from $REPO …"

# Fetch open PRs with basic info
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state open \
  --limit "$COUNT" \
  --json number,title,createdAt,author)

if [[ -z "$PR_JSON" ]] || [[ "$PR_JSON" == "[]" ]]; then
  echo "No open PRs found."
  exit 0
fi

total_files=0
total_prs=0

printf "\nPR#    Files  Author              Title\n"
printf "%s\n" "─────────────────────────────────────────────────────────────────────"

# Process each PR to get file count
echo "$PR_JSON" | jq -r '.[] | @base64' | while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)
  
  num=$(echo "$pr" | jq -r '.number')
  title=$(echo "$pr" | jq -r '.title')
  author=$(echo "$pr" | jq -r '.author.login')
  
  # Fetch files for this PR
  files_count=$(gh api "repos/$REPO/pulls/$num/files" --paginate | jq 'length')
  
  # Truncate title if too long
  truncated_title=$(echo "$title" | cut -c1-40)
  if [[ ${#title} -gt 40 ]]; then
    truncated_title="${truncated_title}…"
  fi
  
  printf "#%-5s %-5s %-18s %s\n" "$num" "$files_count" "$author" "$truncated_title"
  
  total_files=$((total_files + files_count))
  total_prs=$((total_prs + 1))
done

if (( total_prs > 0 )); then
  avg_files=$(awk "BEGIN { printf \"%.1f\", $total_files/$total_prs }")
  printf "\nAnalyzed %d open PRs • Total files: %d • Average: %s files/PR\n" \
    "$total_prs" "$total_files" "$avg_files"
  
  # Flag potentially risky large PRs
  echo
  echo "Large PRs (>10 files) that may need extra review attention:"
  echo "$PR_JSON" | jq -r '.[] | @base64' | while IFS= read -r pr_b64; do
    pr=$(echo "$pr_b64" | base64 --decode)
    num=$(echo "$pr" | jq -r '.number')
    files_count=$(gh api "repos/$REPO/pulls/$num/files" --paginate | jq 'length')
    
    if (( files_count > 10 )); then
      title=$(echo "$pr" | jq -r '.title' | cut -c1-50)
      printf "  • #%s (%d files): %s\n" "$num" "$files_count" "$title"
    fi
  done
fi