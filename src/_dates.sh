#!/usr/bin/env bash
#
# Shared date helpers — sourced by scripts that need date math.
#
# Detects BSD vs GNU date by capability probe rather than $OSTYPE,
# which is unreliable when GNU coreutils shadow the system date on PATH.
#
# Provides:
#   get_cutoff_date <days>       → ISO 8601 timestamp N days ago (UTC)
#   get_date_days_ago <days>     → YYYY-MM-DD N days ago (local)
#   parse_timestamp <iso8601>    → epoch seconds
#   format_date <iso8601>        → YYYY-MM-DD

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
