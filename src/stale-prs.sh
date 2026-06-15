#!/usr/bin/env bash
#
# Stale PRs — surfaces open PRs grouped by age, highlighting ones that
# may need attention or should be closed.
#
# Usage: ./stale-prs.sh owner/repo [limit]
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") owner/repo [limit]

Lists open PRs grouped by age bucket, highlighting stale work that may
need attention or should be closed.

Arguments:
  owner/repo   GitHub repo (e.g. "octocat/hello-world")
  limit        Max open PRs to fetch (default: 100)

Examples:
  $(basename "$0") my-org/my-repo
  $(basename "$0") my-org/my-repo 200
  $(basename "$0") my-org/my-repo --csv > stale-prs.csv

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

# Strip --csv / --json from positional args
args=()
for arg in "$@"; do
  [[ "$arg" != "--csv" && "$arg" != "--json" ]] && args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

resolve_repo "${1:-}" || { usage >&2; exit 1; }
[[ "$_REPO_FROM_ARG" == true ]] && shift
[[ "$JSON" == "true" ]] && json_preflight

LIMIT="${1:-100}"
NOW=$(date +%s)

if [[ "$CSV" == "false" && "$JSON" == "false" ]]; then
  if [[ -n "${ENG_TEAM:-}" ]]; then
    echo "Fetching open PRs for $REPO (team: $ENG_TEAM) …"
  else
    echo "Fetching open PRs for $REPO …"
  fi
fi

if [[ -n "${ENG_TEAM_MEMBERS:-}" ]]; then
  IFS=',' read -ra _members <<< "$ENG_TEAM_MEMBERS"
  _member_count=${#_members[@]}
  _per_member_limit=$(( LIMIT / _member_count ))
  (( _per_member_limit < 10 )) && _per_member_limit=10

  _all_prs="[]"
  for _member in "${_members[@]}"; do
    _member_prs=$(gh pr list \
      --repo "$REPO" \
      --state open \
      --limit "$_per_member_limit" \
      --author "$_member" \
      --json number,title,author,createdAt,updatedAt,isDraft,url 2>/dev/null || echo "[]")
    _all_prs=$(jq -s 'add' <(echo "$_all_prs") <(echo "$_member_prs"))
  done
  PR_JSON=$(echo "$_all_prs" | jq --argjson n "$LIMIT" 'unique_by(.number) | sort_by(.createdAt) | reverse | .[:$n]')
else
  PR_JSON=$(gh pr list \
    --repo "$REPO" \
    --state open \
    --limit "$LIMIT" \
    --json number,title,author,createdAt,updatedAt,isDraft,url)
fi

if [[ -z "$PR_JSON" ]] || [[ "$PR_JSON" == "[]" ]]; then
  if [[ "$JSON" == "true" ]]; then
    empty_data=$(jq -n '{
      open_count: 0,
      buckets: [
        { label: "<1d",  count: 0 },
        { label: "1-3d", count: 0 },
        { label: "3-7d", count: 0 },
        { label: "1-2w", count: 0 },
        { label: "2-4w", count: 0 },
        { label: "30d+", count: 0 }
      ],
      prs: []
    }')
    emit_json "stale-prs" null "$empty_data"
    exit 0
  fi
  echo "No open PRs found."
  exit 0
fi

# Categorize PRs by age
bucket_1d=()
bucket_3d=()
bucket_7d=()
bucket_14d=()
bucket_30d=()
bucket_old=()
pr_records=()

[[ "$CSV" == "true" ]] && echo "PR,Author,Age (days),Draft,Title,URL"

while IFS= read -r pr_b64; do
  pr=$(echo "$pr_b64" | base64 --decode)

  num=$(echo "$pr" | jq -r '.number')
  title=$(echo "$pr" | jq -r '.title' | cut -c1-50)
  author=$(echo "$pr" | jq -r '.author.login')
  created=$(echo "$pr" | jq -r '.createdAt')
  updated=$(echo "$pr" | jq -r '.updatedAt')
  is_draft=$(echo "$pr" | jq -r '.isDraft')
  url=$(echo "$pr" | jq -r '.url')

  ts_created=$(parse_timestamp "$created")
  age_days=$(( (NOW - ts_created) / 86400 ))

  if [[ "$JSON" == "true" ]]; then
    record=$(echo "$pr" | jq -c \
      --argjson age "$age_days" \
      '{
        number: .number,
        author: .author.login,
        age_days: $age,
        is_draft: .isDraft,
        title: .title,
        url: .url
      }')
    pr_records+=("$record")
  fi

  draft_marker=""
  if [[ "$is_draft" == "true" ]]; then
    draft_marker=" [draft]"
  fi

  if [[ "$CSV" == "true" ]]; then
    csv_draft="false"
    [[ "$is_draft" == "true" ]] && csv_draft="true"
    # Escape commas/quotes in title for CSV
    csv_title=$(echo "$title" | sed 's/"/""/g')
    printf "%s,%s,%s,%s,\"%s\",%s\n" "$num" "$author" "$age_days" "$csv_draft" "$csv_title" "$url"
    # still bucket for summary but skip formatted line
    line=""
  else
    line=$(printf "#%-5s  %-18s  %3sd old  %s%s" "$num" "$author" "$age_days" "$title" "$draft_marker")
  fi

  if (( age_days < 1 )); then
    bucket_1d+=("$line")
  elif (( age_days < 3 )); then
    bucket_3d+=("$line")
  elif (( age_days < 7 )); then
    bucket_7d+=("$line")
  elif (( age_days < 14 )); then
    bucket_14d+=("$line")
  elif (( age_days < 30 )); then
    bucket_30d+=("$line")
  else
    bucket_old+=("$line")
  fi
done < <(echo "$PR_JSON" | jq -r '.[] | @base64')

[[ "$CSV" == "true" ]] && exit 0

if [[ "$JSON" == "true" ]]; then
  prs_json=$(printf '%s\n' "${pr_records[@]+"${pr_records[@]}"}" | jq -s '.')
  open_count=$(echo "$PR_JSON" | jq 'length')
  data=$(jq -n \
    --argjson open_count "$open_count" \
    --argjson b1d "${#bucket_1d[@]}" \
    --argjson b3d "${#bucket_3d[@]}" \
    --argjson b7d "${#bucket_7d[@]}" \
    --argjson b14d "${#bucket_14d[@]}" \
    --argjson b30d "${#bucket_30d[@]}" \
    --argjson bold "${#bucket_old[@]}" \
    --argjson prs "$prs_json" \
    '{
      open_count: $open_count,
      buckets: [
        { label: "<1d",  count: $b1d },
        { label: "1-3d", count: $b3d },
        { label: "3-7d", count: $b7d },
        { label: "1-2w", count: $b14d },
        { label: "2-4w", count: $b30d },
        { label: "30d+", count: $bold }
      ],
      prs: $prs
    }')
  emit_json "stale-prs" null "$data"
  exit 0
fi

total=$(echo "$PR_JSON" | jq 'length')

print_bucket() {
  local label="$1"
  shift
  local items=("$@")
  if (( ${#items[@]} > 0 )); then
    printf "\n%s (%d)\n" "$label" "${#items[@]}"
    printf "%s\n" "────────────────────────────────────────────────────────────────────────"
    for item in "${items[@]}"; do
      echo "$item"
    done
  fi
}

printf "\nOpen PRs for %s: %d total\n" "$REPO" "$total"

print_bucket "< 1 day" "${bucket_1d[@]+"${bucket_1d[@]}"}"
print_bucket "1-3 days" "${bucket_3d[@]+"${bucket_3d[@]}"}"
print_bucket "3-7 days" "${bucket_7d[@]+"${bucket_7d[@]}"}"
print_bucket "1-2 weeks" "${bucket_14d[@]+"${bucket_14d[@]}"}"
print_bucket "2-4 weeks" "${bucket_30d[@]+"${bucket_30d[@]}"}"
print_bucket "30+ days" "${bucket_old[@]+"${bucket_old[@]}"}"

# Summary
echo
printf "Age Distribution:\n"
printf "────────────────\n"
printf "  < 1 day:    %d\n" "${#bucket_1d[@]}"
printf "  1-3 days:   %d\n" "${#bucket_3d[@]}"
printf "  3-7 days:   %d\n" "${#bucket_7d[@]}"
printf "  1-2 weeks:  %d\n" "${#bucket_14d[@]}"
printf "  2-4 weeks:  %d\n" "${#bucket_30d[@]}"
printf "  30+ days:   %d\n" "${#bucket_old[@]}"

stale_count=$(( ${#bucket_30d[@]} + ${#bucket_old[@]} ))
if (( stale_count > 0 )); then
  stale_pct=$(awk "BEGIN { printf \"%.0f\", ($stale_count/$total)*100 }")
  echo
  printf "  %d of %d PRs (%s%%) are older than 2 weeks.\n" "$stale_count" "$total" "$stale_pct"
  printf "  Consider reviewing these for closure or re-prioritization.\n"
fi
