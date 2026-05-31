#!/usr/bin/env bash
#
# Pull Discussion — fetches full PR details, comments, review comments,
# and changed files as structured text. Pipe to analyze-discussion.sh
# or an LLM for summarization.
#
# Usage: ./pull-discussion.sh owner/repo PR_NUMBER
# Example: ./pull-discussion.sh my-org/my-repo 42 | ./analyze-discussion.sh
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo PR_NUMBER

Fetches full PR discussion: details, issue comments, review comments,
and changed files. Output is structured text suitable for piping to
an LLM or analyze-discussion.sh.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  PR_NUMBER    Pull request number

Examples:
  $(basename "$0") my-org/my-repo 42
  $(basename "$0") my-org/my-repo 42 | ./analyze-discussion.sh

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

if [[ $# -lt 1 ]]; then
  echo "Error: missing required argument PR_NUMBER" >&2
  usage >&2
  exit 1
fi

PR_NUM="$1"

# Strip ESC (0x1B) from stdin to neutralize ANSI/OSC/CSI/DCS escape
# sequences embedded in untrusted PR content (titles, bodies, filenames,
# comment text). A PR title containing e.g. cursor-move or window-title
# escapes would otherwise render in the user's terminal when this script
# echoes it back. All escape sequences begin with ESC, so dropping that
# single byte neutralizes the whole family.
strip_ansi() {
  tr -d '\033'
}

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
echo "Title: $(echo "$pr_details" | jq -r '.title' | strip_ansi)"
echo "Author: $(echo "$pr_details" | jq -r '.user.login')"
echo "Created: $(echo "$pr_details" | jq -r '.created_at')"
echo "State: $(echo "$pr_details" | jq -r '.state')"
echo "Additions: $(echo "$pr_details" | jq -r '.additions')"
echo "Deletions: $(echo "$pr_details" | jq -r '.deletions')"
echo
echo "Description:"
echo "────────────"
echo "$pr_details" | jq -r '.body' | strip_ansi
echo
echo "Changed Files:"
echo "─────────────"
echo "$changed_files" | jq -r '.[] | "• \(.filename) (+\(.additions) -\(.deletions))"' | strip_ansi
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
  <(echo "$issue_comments") <(echo "$review_comments") | strip_ansi