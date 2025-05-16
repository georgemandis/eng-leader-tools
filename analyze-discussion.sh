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

cat - | llm --system "Analyze the conversation for this PR. Summarize what was broadly discussed, agreed upon, disagreed upon or anything else notable. Focus primarily on discussion between actual Github contributors and not automated comments from services and bots, unless they seem significant."