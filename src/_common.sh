#!/usr/bin/env bash
#
# Shared helpers — sourced by scripts that need date math or repo resolution.
#
# Date helpers detect BSD vs GNU date by capability probe rather than $OSTYPE,
# which is unreliable when GNU coreutils shadow the system date on PATH.
#
# Provides:
#   get_cutoff_date <days>       - ISO 8601 timestamp N days ago (UTC)
#   get_date_days_ago <days>     - YYYY-MM-DD N days ago (local)
#   parse_timestamp <iso8601>    - epoch seconds
#   format_date <iso8601>        - YYYY-MM-DD
#   resolve_repo "$@"            - sets REPO from arg or ENG_REPO

# ── Date helpers ─────────────────────────────────────────────────────

if date -v +0d >/dev/null 2>&1; then
    # BSD date (macOS, FreeBSD)
    get_cutoff_date() {
        date -u -v-"$1"d +"%Y-%m-%dT%H:%M:%SZ"
    }
    get_date_days_ago() {
        date -v-"$1"d +%Y-%m-%d
    }
    parse_timestamp() {
        date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s
    }
    format_date() {
        date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +"%Y-%m-%d"
    }
else
    # GNU date (Linux, macOS with coreutils)
    get_cutoff_date() {
        date -u -d "$1 days ago" +"%Y-%m-%dT%H:%M:%SZ"
    }
    get_date_days_ago() {
        date -d "$1 days ago" +%Y-%m-%d
    }
    parse_timestamp() {
        date -d "$1" +%s
    }
    format_date() {
        date -d "$1" +"%Y-%m-%d"
    }
fi

# ── Repo resolution ─────────────────────────────────────────────────
# Resolves REPO from the first positional arg (if it contains /) or
# from ENG_REPO. Also sets _REPO_FROM_ARG so callers know whether to
# shift.
#
# Usage (in each script, replaces the 10-line resolve block):
#   resolve_repo "${1:-}" || { usage >&2; exit 1; }
#   [[ "$_REPO_FROM_ARG" == true ]] && shift

_REPO_FROM_ARG=false

resolve_repo() {
    _REPO_FROM_ARG=false
    if [[ -n "${1:-}" && "$1" == */* ]]; then
        REPO="$1"
        _REPO_FROM_ARG=true
        return 0
    elif [[ -n "${ENG_REPO:-}" ]]; then
        REPO="$ENG_REPO"
        return 0
    fi
    echo "Error: missing required argument owner/repo (not in a GitHub repo)" >&2
    return 1
}
