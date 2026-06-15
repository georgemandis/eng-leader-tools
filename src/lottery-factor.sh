#!/usr/bin/env bash
#
# Lottery Factor — identifies knowledge concentration risk by finding
# files and directories where only one or two people have made changes.
# (What happens if someone wins the lottery and leaves?)
#
# Usage: ./lottery-factor.sh owner/repo [count] [min_commits]
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [count] [min_commits]

Identifies knowledge concentration risk by analyzing who has contributed
to which files across recent merged PRs. Flags files and directories
where only 1-2 people have made changes.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  count        Number of recent merged PRs to analyze (default: 100)
  min_commits  Minimum file changes to include in analysis (default: 2)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 200 3
  $(basename "$0") my-org/my-repo --csv > lottery-factor.csv

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

# Strip --csv/--json from positional args
args=()
for arg in "$@"; do
  [[ "$arg" != "--csv" && "$arg" != "--json" ]] && args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

resolve_repo "${1:-}" || { usage >&2; exit 1; }
[[ "$_REPO_FROM_ARG" == true ]] && shift

[[ "$JSON" == "true" ]] && json_preflight

COUNT="${1:-100}"
MIN_COMMITS="${2:-2}"

[[ "$CSV" == "false" && "$JSON" == "false" ]] && echo "Analyzing lottery factor for $REPO (last $COUNT merged PRs) …"

# Fetch recent merged PRs with author info
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state merged \
  --limit "$COUNT" \
  --json number,author)

if [[ -z "$PR_JSON" ]] || [[ "$PR_JSON" == "[]" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "lottery-factor" null '{"files":[],"concentrated_count":0}'
    exit 0
  fi
  echo "No merged PRs found."
  exit 0
fi

# Temp file: each line is "author filename"
temp_file=$(mktemp)
trap "rm -f $temp_file" EXIT

total_prs=0

[[ "$CSV" == "false" && "$JSON" == "false" ]] && echo "Fetching file changes per PR (this may take a moment) …"

echo "$PR_JSON" | jq -r '.[] | @base64' | while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)

  num=$(echo "$pr" | jq -r '.number')
  author=$(echo "$pr" | jq -r '.author.login')

  # Get files changed in this PR
  gh api "repos/$REPO/pulls/$num/files" --paginate 2>/dev/null | \
    jq -r --arg author "$author" '.[] | "\($author)\t\(.filename)"' >> "$temp_file"

  total_prs=$((total_prs + 1))
done

if [[ ! -s "$temp_file" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "lottery-factor" null '{"files":[],"concentrated_count":0}'
    exit 0
  fi
  echo "No file changes found."
  exit 0
fi

total_prs=$(echo "$PR_JSON" | jq 'length')

# Analyze: for each file, count unique contributors
# Output: unique_authors total_changes filename
file_analysis=$(awk -F'\t' '
{
  file = $2
  author = $1
  changes[file]++
  if (!seen[file, author]++) {
    authors[file] = (authors[file] ? authors[file] "|" : "") author
    author_count[file]++
  }
}
END {
  for (file in changes) {
    if (changes[file] >= '"$MIN_COMMITS"') {
      printf "%d\t%d\t%s\t%s\n", author_count[file], changes[file], file, authors[file]
    }
  }
}' "$temp_file" | sort -t$'\t' -k1,1n -k2,2nr)

if [[ -z "$file_analysis" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "lottery-factor" null '{"files":[],"concentrated_count":0}'
    exit 0
  fi
  echo "No files with >= $MIN_COMMITS changes found." >&2
  exit 0
fi

# JSON mode: emit one envelope and exit (JSON wins over CSV).
# top_author_share is a TRUE share: the dominant author's change count for a
# file divided by that file's total changes, derived from the same raw
# author/file rows ($temp_file) the table is built from, filtered to the same
# MIN_COMMITS universe as $file_analysis.
if [[ "$JSON" == "true" ]]; then
  files_json=$(awk -F'\t' -v min="$MIN_COMMITS" '
    {
      file = $2; author = $1
      total[file]++
      ac[file SUBSEP author]++
      if (ac[file SUBSEP author] > best[file]) {
        best[file] = ac[file SUBSEP author]
        top[file] = author
      }
    }
    END {
      for (f in total) {
        if (total[f] >= min) {
          share = best[f] / total[f]
          printf "%s\t%s\t%.10f\t%d\n", f, top[f], share, total[f]
        }
      }
    }' "$temp_file" \
    | jq -R -s '
        [ split("\n")[] | select(length > 0) | split("\t")
          | { path: .[0],
              top_author: .[1],
              top_author_share: (.[2] | tonumber),
              total_changes: (.[3] | tonumber) } ]
        | sort_by(-.top_author_share)
        | { files: .,
            concentrated_count: ([ .[] | select(.top_author_share > 0.5) ] | length) }
      ')
  emit_json "lottery-factor" null "$files_json"
  exit 0
fi

# CSV mode: output all file data and exit
if [[ "$CSV" == "true" ]]; then
  echo "File,Unique Authors,Total Changes,Authors"
  echo "$file_analysis" | while IFS=$'\t' read -r author_count changes file authors; do
    display_authors=$(echo "$authors" | tr '|' ';')
    # Escape commas/quotes in filenames
    csv_file=$(echo "$file" | sed 's/"/""/g')
    printf "\"%s\",%s,%s,\"%s\"\n" "$csv_file" "$author_count" "$changes" "$display_authors"
  done
  exit 0
fi

# Files with only 1 contributor
single_author=$(echo "$file_analysis" | awk -F'\t' '$1 == 1')
single_count=$(echo "$single_author" | grep -c . || true)

# Files with only 2 contributors
two_authors=$(echo "$file_analysis" | awk -F'\t' '$1 == 2')
two_count=$(echo "$two_authors" | grep -c . || true)

# Total files analyzed
total_files=$(echo "$file_analysis" | wc -l | tr -d ' ')

printf "\nLottery Factor Analysis:\n"
printf "────────────────────────\n"
printf "  PRs analyzed:    %d\n" "$total_prs"
printf "  Files tracked:   %d (with >= %d changes)\n" "$total_files" "$MIN_COMMITS"
printf "  Single author:   %d files\n" "$single_count"
printf "  Two authors:     %d files\n" "$two_count"

# Show single-author files (highest risk)
if [[ -n "$single_author" ]]; then
  echo
  printf "Single-Contributor Files (highest risk):\n"
  printf "─────────────────────────────────────────\n"
  printf "%-6s  %-18s  %s\n" "Chgs" "Only Author" "File"
  printf "%s\n" "────────────────────────────────────────────────────────────────────────"

  echo "$single_author" | sort -t$'\t' -k2 -nr | head -20 | while IFS=$'\t' read -r _count changes file authors; do
    printf "%-6s  %-18s  %s\n" "$changes" "$authors" "$file"
  done

  if (( single_count > 20 )); then
    printf "  … and %d more\n" "$(( single_count - 20 ))"
  fi
fi

# Show two-author files (moderate risk)
if [[ -n "$two_authors" ]]; then
  echo
  printf "Two-Contributor Files (moderate risk):\n"
  printf "──────────────────────────────────────\n"
  printf "%-6s  %-30s  %s\n" "Chgs" "Authors" "File"
  printf "%s\n" "────────────────────────────────────────────────────────────────────────"

  echo "$two_authors" | sort -t$'\t' -k2 -nr | head -20 | while IFS=$'\t' read -r _count changes file authors; do
    display_authors=$(echo "$authors" | tr '|' ', ')
    printf "%-6s  %-30s  %s\n" "$changes" "$display_authors" "$file"
  done

  if (( two_count > 20 )); then
    printf "  … and %d more\n" "$(( two_count - 20 ))"
  fi
fi

# Directory-level analysis
echo
printf "Directory-Level Risk:\n"
printf "─────────────────────\n"
printf "%-6s  %-6s  %s\n" "Files" "Risk" "Directory"
printf "%s\n" "────────────────────────────────────────────────────────────────────────"

echo "$single_author" | while IFS=$'\t' read -r _count _changes file _authors; do
  dirname "$file"
done | sort | uniq -c | sort -nr | head -10 | while read -r dir_count dirname; do
  if (( dir_count >= 5 )); then
    risk="HIGH"
  elif (( dir_count >= 3 )); then
    risk="MED"
  else
    risk="LOW"
  fi
  printf "%-6s  %-6s  %s\n" "$dir_count" "$risk" "$dirname"
done

# Overall risk assessment
echo
printf "Overall Risk:\n"
printf "─────────────\n"

if (( total_files > 0 )); then
  single_pct=$(awk "BEGIN { printf \"%.0f\", ($single_count/$total_files)*100 }")
  at_risk_pct=$(awk "BEGIN { printf \"%.0f\", (($single_count + $two_count)/$total_files)*100 }")

  printf "  %s%% of active files have a single contributor\n" "$single_pct"
  printf "  %s%% of active files have 2 or fewer contributors\n" "$at_risk_pct"

  if (( single_pct >= 50 )); then
    printf "  Knowledge is highly concentrated — consider pairing or rotating reviewers.\n"
  elif (( single_pct >= 25 )); then
    printf "  Moderate concentration — some areas could benefit from knowledge sharing.\n"
  else
    printf "  Knowledge is well distributed across the team.\n"
  fi
fi
