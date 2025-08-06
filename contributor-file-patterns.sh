#!/usr/bin/env bash
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

REPO="$1"
COUNT="${2:-50}"

echo "Analyzing file change patterns for contributors in $REPO (last $COUNT PRs) …"

# Fetch recent merged PRs with author info
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state merged \
  --limit "$COUNT" \
  --json number,author)

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