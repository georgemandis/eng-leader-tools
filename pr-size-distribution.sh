#!/usr/bin/env bash
#
# PR Size Distribution — categorizes PRs by size (XS through XL) and
# correlates size with review time. Includes distribution health assessment.
#
# Usage: ./pr-size-distribution.sh owner/repo [count]
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

Categorizes merged PRs into size tiers (XS/S/M/L/XL) based on lines
changed and files touched. Shows size distribution, average review times
per tier, and health assessment. Makes one API call per PR for file counts.

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

if [[ $# -lt 1 ]]; then
  echo "Error: missing required argument owner/repo" >&2
  usage >&2
  exit 1
fi

# Detect OS and set appropriate date functions
if [[ "$OSTYPE" == "darwin"* ]]; then
    parse_timestamp() {
        local timestamp=$1
        date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s
    }
    
    format_time() {
        local seconds=$1
        local hours=$(( seconds / 3600 ))
        if (( hours >= 24 )); then
            local days=$(( hours / 24 ))
            printf "%dd" "$days"
        else
            printf "%dh" "$hours"
        fi
    }
else
    parse_timestamp() {
        local timestamp=$1
        date -d "$timestamp" +%s
    }
    
    format_time() {
        local seconds=$1
        local hours=$(( seconds / 3600 ))
        if (( hours >= 24 )); then
            local days=$(( hours / 24 ))
            printf "%dd" "$days"
        else
            printf "%dh" "$hours"
        fi
    }
fi

# Function to categorize PR size
categorize_pr_size() {
    local additions=$1
    local deletions=$2
    local files=$3
    local total_changes=$(( additions + deletions ))
    
    # Size categories based on changes and files
    if (( total_changes <= 50 && files <= 3 )); then
        echo "XS"
    elif (( total_changes <= 200 && files <= 8 )); then
        echo "S"
    elif (( total_changes <= 500 && files <= 15 )); then
        echo "M"
    elif (( total_changes <= 1000 && files <= 25 )); then
        echo "L"
    else
        echo "XL"
    fi
}

REPO="$1"
COUNT="${2:-50}"

echo "Analyzing PR size distribution for $REPO (last $COUNT merged PRs) …"

# Fetch merged PRs with detailed info
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state merged \
  --limit "$COUNT" \
  --json number,title,additions,deletions,createdAt,mergedAt,author,url)

if [[ -z "$PR_JSON" ]] || [[ "$PR_JSON" == "[]" ]]; then
  echo "No merged PRs found."
  exit 0
fi

# Initialize counters
declare -A size_counts
declare -A size_review_times
declare -A size_total_times
size_counts[XS]=0
size_counts[S]=0  
size_counts[M]=0
size_counts[L]=0
size_counts[XL]=0

total_prs=0
total_additions=0
total_deletions=0

printf "\nPR Size Analysis:\n"
printf "─────────────────\n"
printf "%-6s %-4s %-5s %-6s %-8s %-8s %-25s %s\n" "PR#" "Size" "Files" "Lines" "Review" "Author" "Title" "URL"
printf "%s\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────"

# Analyze each PR
echo "$PR_JSON" | jq -r '.[] | @base64' | while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)
  
  num=$(echo "$pr" | jq -r '.number')
  title=$(echo "$pr" | jq -r '.title')
  additions=$(echo "$pr" | jq -r '.additions')
  deletions=$(echo "$pr" | jq -r '.deletions')
  created=$(echo "$pr" | jq -r '.createdAt')
  merged=$(echo "$pr" | jq -r '.mergedAt')
  author=$(echo "$pr" | jq -r '.author.login')
  url=$(echo "$pr" | jq -r '.url')

  # Get file count
  files_count=$(gh api "repos/$REPO/pulls/$num/files" --paginate | jq 'length')
  
  # Calculate review time
  ts_created=$(parse_timestamp "$created")
  ts_merged=$(parse_timestamp "$merged")
  review_time_sec=$(( ts_merged - ts_created ))
  review_time=$(format_time "$review_time_sec")
  
  # Categorize PR size
  size=$(categorize_pr_size "$additions" "$deletions" "$files_count")
  
  total_lines=$(( additions + deletions ))
  
  # Truncate title and author for display
  short_title=$(echo "$title" | cut -c1-25)
  short_author=$(echo "$author" | cut -c1-8)
  
  printf "#%-5s %-4s %-5s %-6s %-8s %-8s %-25s %s\n" \
    "$num" "$size" "$files_count" "$total_lines" "$review_time" "$short_author" "$short_title" "$url"
  
  # Accumulate stats
  size_counts[$size]=$((size_counts[$size] + 1))
  size_total_times[$size]=$((${size_total_times[$size]:-0} + review_time_sec))
  
  total_prs=$((total_prs + 1))
  total_additions=$((total_additions + additions))
  total_deletions=$((total_deletions + deletions))
done

if (( total_prs == 0 )); then
  exit 0
fi

# Display distribution
echo
printf "Size Distribution:\n"
printf "──────────────────\n"
printf "%-4s %-5s %-6s %s\n" "Size" "Count" "%" "Avg Review Time"
printf "%s\n" "────────────────────────────────────"

for size in XS S M L XL; do
  count=${size_counts[$size]}
  if (( count > 0 )); then
    percentage=$(awk "BEGIN { printf \"%.1f\", ($count/$total_prs)*100 }")
    avg_time_sec=$(( size_total_times[$size] / count ))
    avg_time=$(format_time "$avg_time_sec")
    printf "%-4s %-5s %-6s %s\n" "$size" "$count" "$percentage%" "$avg_time"
  else
    printf "%-4s %-5s %-6s %s\n" "$size" "0" "0.0%" "N/A"
  fi
done

# Summary stats
echo
printf "Summary Statistics:\n"
printf "───────────────────\n"
printf "• Total PRs analyzed: %d\n" "$total_prs"
printf "• Total lines changed: %d (+%d -%d)\n" "$((total_additions + total_deletions))" "$total_additions" "$total_deletions"

avg_additions=$(( total_additions / total_prs ))
avg_deletions=$(( total_deletions / total_prs ))
printf "• Average lines per PR: %d (+%d -%d)\n" "$((avg_additions + avg_deletions))" "$avg_additions" "$avg_deletions"

# Size recommendations
echo
printf "Size Distribution Health:\n"
printf "─────────────────────────\n"

small_prs=$(( size_counts[XS] + size_counts[S] ))
large_prs=$(( size_counts[L] + size_counts[XL] ))

small_percentage=$(awk "BEGIN { printf \"%.0f\", ($small_prs/$total_prs)*100 }")
large_percentage=$(awk "BEGIN { printf \"%.0f\", ($large_prs/$total_prs)*100 }")

if (( small_percentage >= 60 )); then
  echo "• 🟢 Good: ${small_percentage}% small PRs (XS/S) - easier to review"
elif (( small_percentage >= 40 )); then
  echo "• 🟡 Moderate: ${small_percentage}% small PRs - could improve"
else
  echo "• 🔴 Poor: ${small_percentage}% small PRs - consider breaking down work"
fi

if (( large_percentage >= 30 )); then
  echo "• 🔴 Concern: ${large_percentage}% large PRs (L/XL) - harder to review thoroughly"
elif (( large_percentage >= 15 )); then
  echo "• 🟡 Watch: ${large_percentage}% large PRs - monitor review quality"
else
  echo "• 🟢 Good: ${large_percentage}% large PRs - manageable review load"
fi

# Show correlation between size and review time
echo
printf "Size vs Review Time Correlation:\n"
printf "─────────────────────────────────\n"

if (( size_counts[XS] > 0 && size_counts[XL] > 0 )); then
  xs_avg=$(( size_total_times[XS] / size_counts[XS] ))
  xl_avg=$(( size_total_times[XL] / size_counts[XL] ))
  
  if (( xl_avg > xs_avg * 2 )); then
    echo "• Large PRs take significantly longer to review"
    echo "  Consider breaking them into smaller chunks"
  else
    echo "• Review times don't strongly correlate with PR size"
    echo "  May indicate consistent review practices"
  fi
fi