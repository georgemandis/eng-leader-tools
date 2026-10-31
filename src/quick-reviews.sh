#!/usr/bin/env bash
set -euo pipefail

# Default values
OWNER="${ENG_OWNER:-}"
REPO="${ENG_REPO:+${ENG_REPO##*/}}"
LIMIT=100
# MODE is one of:
#   unapproved  small (1-2 file) open PRs not yet approved (default)
#   all         small open PRs regardless of approval (-a)
#   approved    approved-but-unmerged open PRs of any size (-A)
MODE=unapproved
SAW_a=false
SAW_A=false
CSV=false

# Pull --csv out before getopts, which only understands single-dash flags.
_args=()
for arg in "$@"; do
  if [[ "$arg" == "--csv" ]]; then CSV=true; else _args+=("$arg"); fi
done
set -- "${_args[@]+"${_args[@]}"}"

# Parse command line flags
while getopts "o:r:l:aAh" opt; do
  case $opt in
    o) OWNER="$OPTARG" ;;
    r) REPO="$OPTARG" ;;
    l) LIMIT="$OPTARG" ;;
    a) MODE=all; SAW_a=true ;;
    A) MODE=approved; SAW_A=true ;;
    h)
      cat <<EOF2
Usage: $(basename "$0") -o owner -r repo [-l limit] [-a | -A] [--csv]

Surfaces small open PRs (1-2 files, non-draft) that haven't been
approved yet — quick wins for reviewers looking to help unblock work.

With -A it instead lists open PRs that are already approved but still
unmerged, of any size, oldest activity first — the "dead time" between
approval and merge.

Options:
  -o owner    GitHub owner/organization (required)
  -r repo     Repository name (required)
  -l limit    Number of PRs to fetch (default: 100)
  -a          Include approved PRs (default: only show unapproved)
  -A          Only approved-but-unmerged PRs, any size (cannot combine with -a)
  --csv       Output as CSV instead of formatted list
  -h          Show this help

Examples:
  $(basename "$0") -o my-org -r my-repo
  $(basename "$0") -o my-org -r my-repo -a -l 200
  $(basename "$0") -o my-org -r my-repo -A
  $(basename "$0") -o my-org -r my-repo --csv > quick-reviews.csv

Requires: gh (authenticated), jq
EOF2
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      echo "Use -h for help"
      exit 1
      ;;
  esac
done

if [[ "$SAW_a" == true && "$SAW_A" == true ]]; then
  echo "Error: -A (approved only) and -a (include approved) cannot be combined" >&2
  echo "Use -h for help" >&2
  exit 1
fi

if [[ -z "$OWNER" || -z "$REPO" ]]; then
  echo "Error: -o owner and -r repo are required" >&2
  echo "Use -h for help" >&2
  exit 1
fi

_team_label=""
[[ -n "${ENG_TEAM:-}" ]] && _team_label=" (team: $ENG_TEAM)"

# Fetch open PRs. With a team filter, one query per member (deduped below).
if [[ -n "${ENG_TEAM_MEMBERS:-}" ]]; then
  IFS=',' read -ra _members <<< "$ENG_TEAM_MEMBERS"
  _member_count=${#_members[@]}
  _per_member_limit=$(( LIMIT / _member_count ))
  (( _per_member_limit < 10 )) && _per_member_limit=10

  _pr_data="[]"
  for _member in "${_members[@]}"; do
    _member_prs=$(gh pr list \
      --repo "$OWNER/$REPO" \
      --state open \
      --limit "$_per_member_limit" \
      --author "$_member" \
      --json number,title,url,author,changedFiles,updatedAt,reviewDecision,isDraft 2>/dev/null || echo "[]")
    _pr_data=$(jq -s 'add' <(echo "$_pr_data") <(echo "$_member_prs"))
  done
else
  _pr_data=$(gh pr list \
    --repo "$OWNER/$REPO" \
    --state open \
    --limit "$LIMIT" \
    --json number,title,url,author,changedFiles,updatedAt,reviewDecision,isDraft)
fi

# Shared jq program. Filters by mode, then renders as CSV or a list.
# approved mode: any size, oldest activity first, with an age-in-days column.
# other modes:   1-2 files, newest activity first.
_filter='
  def age_days: ((now - (.updatedAt | fromdateiso8601)) / 86400 | floor);
  def date: .updatedAt | split("T")[0];
  def csv_title: .title | gsub("\""; "\"\"");

  unique_by(.number) |
  map(select(.isDraft == false)) |
  if $mode == "approved" then
    map(select(.reviewDecision == "APPROVED")) | sort_by(.updatedAt)
  else
    map(select(.changedFiles <= 2 and .changedFiles >= 1)) |
    (if $mode == "unapproved" then map(select(.reviewDecision != "APPROVED")) else . end) |
    sort_by(.updatedAt) | reverse
  end |

  if $csv then
    if $mode == "approved" then
      "Date,Age,Title,Author,Files,URL",
      (.[] | "\(date),\(age_days),\"\(csv_title)\",\(.author.login),\(.changedFiles),\(.url)")
    else
      "Date,Title,Author,Files,URL",
      (.[] | "\(date),\"\(csv_title)\",\(.author.login),\(.changedFiles),\(.url)")
    end
  elif length == 0 then
    if $mode == "approved" then "No approved, unmerged PRs found\($team_label)"
    elif $mode == "unapproved" then "No unapproved PRs found with 1-2 file changes\($team_label)"
    else "No PRs found with 1-2 file changes\($team_label)"
    end
  elif $mode == "approved" then
    .[] | "\(age_days)d • \(date) • \(.title) • \(.changedFiles) files • \(.url)"
  else
    .[] | "\(date) • \(.title) • \(.url)"
  end
'

echo "$_pr_data" | jq -r \
  --arg mode "$MODE" \
  --argjson csv "$CSV" \
  --arg team_label "$_team_label" \
  "$_filter"
