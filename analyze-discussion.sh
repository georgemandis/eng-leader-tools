#!/usr/bin/env bash
#
# Analyze Discussion — pipes PR discussion text (from stdin) into an LLM
# for summarization. Designed to be used with pull-discussion.sh.
#
# Usage: ./pull-discussion.sh owner/repo PR_NUMBER | ./analyze-discussion.sh
#
# Requirements:
#   - llm (CLI tool, e.g. https://github.com/simonw/llm)
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: <stdin> | $(basename "$0")

Pipes PR discussion text into an LLM for summarization. Reads from
stdin — designed to be used with pull-discussion.sh.

Examples:
  ./pull-discussion.sh my-org/my-repo 42 | $(basename "$0")

Requires: llm (https://github.com/simonw/llm)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

cat - | llm --system "Analyze the conversation for this PR. Summarize what was broadly discussed, agreed upon, disagreed upon or anything else notable. Focus primarily on discussion between actual Github contributors and not automated comments from services and bots, unless they seem significant."