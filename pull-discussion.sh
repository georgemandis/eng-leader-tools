#!/usr/bin/env bash
#
# Usage: ./pr_comments.sh owner/repo PR_NUMBER
# Example: ./pr_comments.sh my-org/my-repo 42 | llm "Please summarize the following PR discussion:"
#
# Requirements:
#   • gh (GitHub CLI) authenticated
#   • jq
#

set -euo pipefail

REPO="$1"    # e.g. "octocat/hello-world"
PR_NUM="$2"  # e.g. "42"

# 1) Fetch PR details
pr_details=$(gh api "repos/$REPO/pulls/$PR_NUM")

# 2) Fetch issue comments
issue_comments=$(gh api \
  --paginate "repos/$REPO/issues/$PR_NUM/comments")

# 3) Fetch review comments
review_comments=$(gh api \
  --paginate "repos/$REPO/pulls/$PR_NUM/comments")

# 4) Fetch changed files
changed_files=$(gh api \
  --paginate "repos/$REPO/pulls/$PR_NUM/files")

# 5) Format and combine all information
echo "PR Details:"
echo "──────────"
echo "Title: $(echo "$pr_details" | jq -r '.title')"
echo "Author: $(echo "$pr_details" | jq -r '.user.login')"
echo "Created: $(echo "$pr_details" | jq -r '.created_at')"
echo "State: $(echo "$pr_details" | jq -r '.state')"
echo "Additions: $(echo "$pr_details" | jq -r '.additions')"
echo "Deletions: $(echo "$pr_details" | jq -r '.deletions')"
echo
echo "Description:"
echo "────────────"
echo "$(echo "$pr_details" | jq -r '.body')"
echo
echo "Changed Files:"
echo "─────────────"
echo "$changed_files" | jq -r '.[] | "• \(.filename) (+\(.additions) -\(.deletions))"'
echo
echo "Discussion:"
echo "───────────"
jq -s '.[0] + .[1] | sort_by(.created_at) | .[] |
  "Author: \(.user.login) (\(.author_association))\n" +
  "Date:   \(.created_at)\n" +
  (if .path != null then "File:   \(.path):\(.line)\n" else "" end) +
  "Link:   \(.html_url)\n" +
  (if .reactions.total_count > 0 then
    "Reactions: " + (
      [.reactions | to_entries | .[] | select(.value > 0) | "\(.key): \(.value)"]
      | join(", ")
    ) + "\n"
  else "" end) +
  "\n\(.body)\n\n───"' \
  <(echo "$issue_comments") <(echo "$review_comments")