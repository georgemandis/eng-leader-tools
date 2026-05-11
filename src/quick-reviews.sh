#!/usr/bin/env bash
set -euo pipefail

# Default values
OWNER=""
REPO=""
LIMIT=100
ONLY_UNAPPROVED=true

# Parse command line flags
while getopts "o:r:l:ah" opt; do
  case $opt in
    o) OWNER="$OPTARG" ;;
    r) REPO="$OPTARG" ;;
    l) LIMIT="$OPTARG" ;;
    a) ONLY_UNAPPROVED=false ;;
    h)
      cat <<EOF
Usage: $(basename "$0") -o owner -r repo [-l limit] [-a]

Surfaces small open PRs (1-2 files, non-draft) that haven't been
approved yet — quick wins for reviewers looking to help unblock work.

Options:
  -o owner    GitHub owner/organization (required)
  -r repo     Repository name (required)
  -l limit    Number of PRs to fetch (default: 100)
  -a          Include approved PRs (default: only show unapproved)
  -h          Show this help

Examples:
  $(basename "$0") -o my-org -r my-repo
  $(basename "$0") -o my-org -r my-repo -a -l 200

Requires: gh (authenticated), jq
EOF
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      echo "Use -h for help"
      exit 1
      ;;
  esac
done

if [[ -z "$OWNER" || -z "$REPO" ]]; then
  echo "Error: -o owner and -r repo are required" >&2
  echo "Use -h for help" >&2
  exit 1
fi

# Get PRs and filter by changed files count (1 or 2 files) and approval status
gh pr list \
  --repo "$OWNER/$REPO" \
  --state open \
  --limit "$LIMIT" \
  --json number,title,url,author,changedFiles,updatedAt,reviewDecision,isDraft \
  | jq -r --argjson only_unapproved "$ONLY_UNAPPROVED" '
    # Filter to 1-2 files, exclude drafts, and optionally filter by approval status
    map(select(.changedFiles <= 2 and .changedFiles >= 1 and .isDraft == false)) |
    if $only_unapproved then
      map(select(.reviewDecision != "APPROVED"))
    else
      .
    end |
    # Sort by updatedAt descending (newest first)
    sort_by(.updatedAt) | reverse |
    if length == 0 then
      if $only_unapproved then
        "No unapproved PRs found with 1-2 file changes in \($owner)/\($repo)"
      else
        "No PRs found with 1-2 file changes in \($owner)/\($repo)"
      end
    else
      .[] | "\(.updatedAt | split("T")[0]) • \(.title) • \(.url)"
    end
  ' --arg owner "$OWNER" --arg repo "$REPO"