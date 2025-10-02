#!/usr/bin/env bash
#
# Usage: ./track-contributions.sh username [org] [days] [--verbose]
#   username   GitHub username to track
#   org        GitHub org (optional, searches across accessible repos if not provided)
#   days       number of days to look back (default: 30)
#   --verbose  Include full comment text in output
#
# Requirements:
#   - gh (GitHub CLI) authenticated
#   - jq
#

set -euo pipefail

VERBOSE=false

# Detect OS and set appropriate date functions
if [[ "$OSTYPE" == "darwin"* ]]; then
    get_date_days_ago() {
        date -v-"$1"d +%Y-%m-%d
    }
else
    get_date_days_ago() {
        date -d "$1 days ago" +%Y-%m-%d
    }
fi

# Parse arguments
USERNAME=""
ORG=""
DAYS="30"

for arg in "$@"; do
    if [[ "$arg" == "--verbose" ]]; then
        VERBOSE=true
    elif [[ -z "$USERNAME" ]]; then
        USERNAME="$arg"
    elif [[ -z "$ORG" ]]; then
        ORG="$arg"
    else
        DAYS="$arg"
    fi
done

if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 username [org] [days] [--verbose]"
    exit 1
fi

SINCE=$(get_date_days_ago "$DAYS")

echo "Tracking contributions for @$USERNAME (last $DAYS days since $SINCE) …"
echo

# Build base search arguments
base_args="--json number,repository,url,createdAt,author --limit 1000"
owner_arg=""
if [[ -n "$ORG" ]]; then
    owner_arg="--owner $ORG"
fi

# Search using two separate queries and combine results
# Only search for explicit activity (comments and reviews), not mentions or review requests
# 1. PRs where user commented
commented_prs=$(gh search prs $base_args --updated ">=$SINCE" $owner_arg --commenter "$USERNAME" 2>/dev/null || echo "[]")

# 2. PRs where user actually reviewed (not just requested to review)
reviewed_prs=$(gh search prs $base_args --updated ">=$SINCE" $owner_arg --reviewed-by "$USERNAME" 2>/dev/null || echo "[]")

# Combine and deduplicate by PR number + repo
PR_DATA=$(jq -s 'add | unique_by(.repository.nameWithOwner + "-" + (.number | tostring))' \
    <(echo "$commented_prs") \
    <(echo "$reviewed_prs"))

if [[ -z "$PR_DATA" ]] || [[ "$PR_DATA" == "[]" ]]; then
    echo "No PRs found involving @$USERNAME in the specified period."
    exit 0
fi

# Filter out PRs authored by the user (we only want their review/comment activity)
FILTERED_PRS=$(echo "$PR_DATA" | jq --arg user "$USERNAME" '[.[] | select(.author.login != $user)]')

if [[ "$FILTERED_PRS" == "[]" ]]; then
    echo "No PRs found where @$USERNAME left reviews or comments (excluding their own PRs)."
    exit 0
fi

printf "Contribution Activity:\n"
printf "─────────────────────\n"
printf "%-12s %-40s %-8s %-15s %-8s %s\n" "Date" "Repo" "PR#" "Author" "Comments" "Review Status"
printf "%s\n" "─────────────────────────────────────────────────────────────────────────────────────────────────"

total_prs=0
total_comments=0
total_approvals=0
total_change_requests=0

# Process each PR using process substitution to avoid subshell issue
while IFS= read -r pr_b64; do
    pr=$(echo "$pr_b64" | base64 --decode)

    pr_number=$(echo "$pr" | jq -r '.number')
    repo_name=$(echo "$pr" | jq -r '.repository.nameWithOwner')
    pr_url=$(echo "$pr" | jq -r '.url')
    pr_author=$(echo "$pr" | jq -r '.author.login')

    # Get all reviews by this user
    reviews=$(gh api "repos/$repo_name/pulls/$pr_number/reviews" --paginate 2>/dev/null || echo "[]")
    user_reviews=$(echo "$reviews" | jq --arg user "$USERNAME" '[.[] | select(.user.login == $user)]')

    # Get all issue comments by this user
    issue_comments=$(gh api "repos/$repo_name/issues/$pr_number/comments" --paginate 2>/dev/null || echo "[]")
    user_issue_comments=$(echo "$issue_comments" | jq --arg user "$USERNAME" '[.[] | select(.user.login == $user)]')

    # Get all review comments by this user
    review_comments=$(gh api "repos/$repo_name/pulls/$pr_number/comments" --paginate 2>/dev/null || echo "[]")
    user_review_comments=$(echo "$review_comments" | jq --arg user "$USERNAME" '[.[] | select(.user.login == $user)]')

    # Calculate totals
    review_count=$(echo "$user_reviews" | jq 'length')
    issue_comment_count=$(echo "$user_issue_comments" | jq 'length')
    review_comment_count=$(echo "$user_review_comments" | jq 'length')

    # Count review bodies that have text (not empty)
    review_body_count=$(echo "$user_reviews" | jq '[.[] | select(.body != null and .body != "")] | length')

    total_user_comments=$((issue_comment_count + review_comment_count + review_body_count))

    # Skip if user had no actual activity on this PR
    if (( total_user_comments == 0 && review_count == 0 )); then
        continue
    fi

    # Determine review status
    review_status="N/A"
    if (( review_count > 0 )); then
        # Get the most recent review state
        latest_review_state=$(echo "$user_reviews" | jq -r 'max_by(.submitted_at) | .state')
        case "$latest_review_state" in
            "APPROVED")
                review_status="✓ Approved"
                total_approvals=$((total_approvals + 1))
                ;;
            "CHANGES_REQUESTED")
                review_status="⚠ Changes Req"
                total_change_requests=$((total_change_requests + 1))
                ;;
            "COMMENTED")
                review_status="Commented"
                ;;
            *)
                review_status="Other"
                ;;
        esac
    elif (( total_user_comments > 0 )); then
        review_status="Commented"
    fi

    # Get the date of the latest activity by this user
    activity_timestamp=$(jq -s -r 'add | [.[] | .submitted_at // .created_at] | sort | last' \
        <(echo "$user_reviews") \
        <(echo "$user_issue_comments") \
        <(echo "$user_review_comments") 2>/dev/null)

    if [[ -z "$activity_timestamp" || "$activity_timestamp" == "null" ]]; then
        activity_date="Unknown"
    else
        activity_date=$(echo "$activity_timestamp" | cut -d'T' -f1)

        # Skip if user's activity is older than our date range
        if [[ "$activity_date" < "$SINCE" ]]; then
            continue
        fi
    fi

    printf "%-12s %-40s #%-7s %-15s %-8s %s\n" \
        "$activity_date" \
        "$repo_name" \
        "$pr_number" \
        "$pr_author" \
        "$total_user_comments" \
        "$review_status"

    echo "PR: $pr_url"

    # Extract and display individual comment URLs (and text if verbose)
    if (( review_body_count > 0 )); then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$user_reviews" | jq -r '.[] | select(.body != null and .body != "") | "  Review: \(.html_url)\n    \(.body)\n"'
        else
            echo "$user_reviews" | jq -r '.[] | select(.body != null and .body != "") | "  Review: \(.html_url)"'
        fi
    fi

    if (( issue_comment_count > 0 )); then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$user_issue_comments" | jq -r '.[] | "  Comment: \(.html_url)\n    \(.body)\n"'
        else
            echo "$user_issue_comments" | jq -r '.[] | "  Comment: \(.html_url)"'
        fi
    fi

    if (( review_comment_count > 0 )); then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$user_review_comments" | jq -r '.[] | "  Review comment: \(.html_url)\n    \(.body)\n"'
        else
            echo "$user_review_comments" | jq -r '.[] | "  Review comment: \(.html_url)"'
        fi
    fi

    echo

    total_prs=$((total_prs + 1))
    total_comments=$((total_comments + total_user_comments))
done < <(echo "$FILTERED_PRS" | jq -r '.[] | @base64')

printf "\nSummary:\n"
printf "────────\n"
printf "• Total PRs reviewed/commented: %d\n" "$total_prs"
printf "• Total comments left: %d\n" "$total_comments"
printf "• Approvals: %d\n" "$total_approvals"
printf "• Change requests: %d\n" "$total_change_requests"

if (( total_prs > 0 )); then
    avg_comments=$(awk "BEGIN { printf \"%.1f\", $total_comments / $total_prs }")
    printf "• Average comments per PR: %s\n" "$avg_comments"
fi
