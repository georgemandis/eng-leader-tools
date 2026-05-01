#!/usr/bin/env bash
#
# Dependency Changes — tracks dependency update PRs, flags security updates,
# and measures automation rate (Dependabot, Renovate, etc.).
#
# Usage: ./dependency-changes.sh owner/repo [days]
#   owner/repo   GitHub repo (e.g. "octocat/hello-world")
#   days         lookback window in days (default: 90)
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [days]

Identifies merged PRs that modify dependency files (package.json, go.mod,
Cargo.toml, requirements.txt, etc.). Flags security updates, measures
automation rate, and provides a dependency health assessment.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  days         Lookback window in days (default: 90)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 180

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
    get_cutoff_date() {
        local days=$1
        date -u -v-"$days"d +"%Y-%m-%dT%H:%M:%SZ"
    }
    
    format_date() {
        local timestamp=$1
        date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +"%Y-%m-%d"
    }
else
    get_cutoff_date() {
        local days=$1
        date -u -d "$days days ago" +"%Y-%m-%dT%H:%M:%SZ"
    }
    
    format_date() {
        local timestamp=$1
        date -d "$timestamp" +"%Y-%m-%d"
    }
fi

REPO="$1"
DAYS="${2:-90}"

CUTOFF=$(get_cutoff_date "$DAYS")

echo "Analyzing dependency changes for $REPO (last $DAYS days) …"

# Common dependency files to look for
dependency_patterns=(
  "package.json"
  "package-lock.json"
  "yarn.lock"
  "requirements.txt"
  "requirements/*.txt"
  "Pipfile"
  "Pipfile.lock"
  "composer.json"
  "composer.lock"
  "Gemfile"
  "Gemfile.lock"
  "go.mod"
  "go.sum"
  "Cargo.toml"
  "Cargo.lock"
  "pom.xml"
  "build.gradle"
  "build.gradle.kts"
  "pubspec.yaml"
  "pubspec.lock"
)

# Fetch merged PRs since cutoff
PR_JSON=$(gh pr list \
  --repo "$REPO" \
  --state merged \
  --limit 200 \
  --json number,title,mergedAt,author,url \
  --jq ".[] | select(.mergedAt >= \"$CUTOFF\")")

if [[ -z "$PR_JSON" ]]; then
  echo "No PRs merged in the last $DAYS days."
  exit 0
fi

total_prs=$(echo "$PR_JSON" | jq -s 'length')
dependency_prs=()
security_prs=()

printf "\nDependency Management Analysis:\n"
printf "───────────────────────────────\n"

# Analyze each PR for dependency changes
echo "$PR_JSON" | jq -r '@base64' | while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)
  
  num=$(echo "$pr" | jq -r '.number')
  title=$(echo "$pr" | jq -r '.title')
  merged_at=$(echo "$pr" | jq -r '.mergedAt')
  author=$(echo "$pr" | jq -r '.author.login')
  url=$(echo "$pr" | jq -r '.url')

  # Get files changed in this PR
  files_json=$(gh api "repos/$REPO/pulls/$num/files" --paginate)
  
  # Check if any dependency files were modified
  dependency_files=()
  for pattern in "${dependency_patterns[@]}"; do
    matches=$(echo "$files_json" | jq -r --arg pattern "$pattern" \
      '.[] | select(.filename | test($pattern)) | .filename')
    
    if [[ -n "$matches" ]]; then
      while IFS= read -r file; do
        [[ -n "$file" ]] && dependency_files+=("$file")
      done <<< "$matches"
    fi
  done
  
  if [[ ${#dependency_files[@]} -gt 0 ]]; then
    formatted_date=$(format_date "$merged_at")
    
    # Check if this looks like a security update
    is_security=""
    if echo "$title" | grep -qi -E "(security|vulnerability|cve-|bump.*security|dependabot.*security)"; then
      is_security=" 🔒"
      security_prs+=("$num")
    fi
    
    # Check if it's an automated dependency update
    is_automated=""
    if echo "$author" | grep -qi -E "(dependabot|renovate|greenkeeper)" || \
       echo "$title" | grep -qi -E "(bump|update.*dependencies|chore\(deps\))"; then
      is_automated=" 🤖"
    fi
    
    printf "#%-5s %s %-18s%s%s\n" "$num" "$formatted_date" "$author" "$is_security" "$is_automated"
    printf "       %s\n" "$(echo "$title" | cut -c1-60)"
    printf "       %s\n" "$url"
    printf "       Files: %s\n\n" "$(IFS=', '; echo "${dependency_files[*]}")"
    
    dependency_prs+=("$num")
  fi
done

dep_count=${#dependency_prs[@]}
security_count=${#security_prs[@]}

printf "Summary:\n"
printf "────────\n"
printf "• Total PRs analyzed: %d\n" "$total_prs"
printf "• PRs with dependency changes: %d\n" "$dep_count"
printf "• Security-related updates: %d\n" "$security_count"

if (( dep_count > 0 )); then
  dep_percentage=$(awk "BEGIN { printf \"%.1f\", ($dep_count/$total_prs)*100 }")
  printf "• Dependency change rate: %s%%\n" "$dep_percentage"
  
  # Calculate frequency
  if (( dep_count > 0 )); then
    avg_days=$(awk "BEGIN { printf \"%.1f\", $DAYS/$dep_count }")
    printf "• Average frequency: Every %s days\n" "$avg_days"
  fi
fi

# Health assessment
echo
printf "Dependency Health Assessment:\n"
printf "─────────────────────────────\n"

if (( security_count > 0 )); then
  echo "• 🔒 Security updates: $security_count found"
  if (( security_count >= dep_count / 2 )); then
    echo "  ⚠️  High security update ratio - review security practices"
  else
    echo "  ✅ Reasonable security update frequency"
  fi
fi

# Frequency assessment
if (( dep_count == 0 )); then
  echo "• 🔴 No dependency updates - dependencies may be stale"
elif (( dep_count >= DAYS / 7 )); then
  echo "• 🟢 Active dependency management (weekly+ updates)"
elif (( dep_count >= DAYS / 30 )); then
  echo "• 🟡 Moderate dependency management (monthly updates)"
else
  echo "• 🟠 Infrequent dependency updates (less than monthly)"
fi

# Automation assessment
automated_count=0
echo "$PR_JSON" | jq -r '@base64' | while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)
  author=$(echo "$pr" | jq -r '.author.login')
  title=$(echo "$pr" | jq -r '.title')
  
  if echo "$author" | grep -qi -E "(dependabot|renovate|greenkeeper)" || \
     echo "$title" | grep -qi -E "(bump|update.*dependencies|chore\(deps\))"; then
    automated_count=$((automated_count + 1))
  fi
done

if (( dep_count > 0 )); then
  automation_rate=$(awk "BEGIN { printf \"%.0f\", ($automated_count/$dep_count)*100 }")
  
  if (( automation_rate >= 70 )); then
    echo "• 🤖 High automation: ${automation_rate}% of dependency updates automated"
  elif (( automation_rate >= 30 )); then
    echo "• 🟡 Moderate automation: ${automation_rate}% automated"
  else
    echo "• 🔴 Low automation: ${automation_rate}% automated - consider tools like Dependabot"
  fi
fi