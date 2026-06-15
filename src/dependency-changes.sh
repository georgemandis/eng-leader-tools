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
Usage: $(basename "$0") owner/repo [days] [--json]

Identifies merged PRs that modify dependency files (package.json, go.mod,
Cargo.toml, requirements.txt, etc.). Flags security updates, measures
automation rate, and provides a dependency health assessment.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  days         Lookback window in days (default: 90)

Options:
  --json       Emit a single JSON envelope instead of the table output.

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

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Parse flags; strip recognized flags from positional args.
JSON=false
args=()
for arg in "$@"; do
  case "$arg" in
    --json) JSON=true ;;
    *) args+=("$arg") ;;
  esac
done
set -- "${args[@]}"

resolve_repo "${1:-}" || { usage >&2; exit 1; }
[[ "$_REPO_FROM_ARG" == true ]] && shift

DAYS="${1:-90}"

[[ "$JSON" == "true" ]] && json_preflight

CUTOFF=$(get_cutoff_date "$DAYS")

[[ "$JSON" == "false" ]] && echo "Analyzing dependency changes for $REPO (last $DAYS days) …"

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
  if [[ "$JSON" == "true" ]]; then
    emit_json "dependency-changes" "$DAYS" '{"manifest_changes":[],"total_dependency_prs":0}'
    exit 0
  fi
  echo "No PRs merged in the last $DAYS days."
  exit 0
fi

# ── JSON mode ────────────────────────────────────────────────────────
# Compute the JSON data with a dedicated pass rather than relying on the
# subshell display loops below. Uses the same manifest-matching logic
# (dependency_patterns + jq test()).
if [[ "$JSON" == "true" ]]; then
  # Build a jq array of the dependency patterns.
  patterns_json=$(printf '%s\n' "${dependency_patterns[@]}" | jq -R . | jq -s .)

  # Per-manifest-file change counts (one count per PR that touched that file)
  # and total number of PRs touching any dependency manifest.
  manifest_counts_file=$(mktemp)
  total_dep_prs=0

  while IFS= read -r pr_b64; do
    [[ -z "$pr_b64" ]] && continue
    pr=$(echo "$pr_b64" | base64 --decode)
    num=$(echo "$pr" | jq -r '.number')

    files_json=$(gh api "repos/$REPO/pulls/$num/files" --paginate)

    # Matched manifest filenames for this PR (deduped), one per line.
    matched=$(echo "$files_json" | jq -r --argjson patterns "$patterns_json" '
      [ .[] | .filename as $f
        | select(any($patterns[]; . as $p | $f | test($p))) | $f ]
      | unique | .[]')

    if [[ -n "$matched" ]]; then
      total_dep_prs=$((total_dep_prs + 1))
      printf '%s\n' "$matched" >> "$manifest_counts_file"
    fi
  done < <(echo "$PR_JSON" | jq -r '@base64')

  manifest_changes=$(sort "$manifest_counts_file" | uniq -c | jq -R '
      ltrimstr(" ") | gsub("^ +";"") | capture("^(?<count>[0-9]+) +(?<file>.*)$")
      | {file: .file, change_count: (.count | tonumber)}' | jq -s 'sort_by(-.change_count)')
  rm -f "$manifest_counts_file"

  data=$(jq -n \
    --argjson manifest_changes "$manifest_changes" \
    --argjson total "$total_dep_prs" \
    '{manifest_changes: $manifest_changes, total_dependency_prs: $total}')

  emit_json "dependency-changes" "$DAYS" "$data"
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