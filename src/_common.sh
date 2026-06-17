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

# ── JSON output helpers ──────────────────────────────────────────────
# These power the `--json` output mode consumed by the Engleader Reports app.
# See docs/json-contract.md for the full contract.

# emit_json <metric> <window_days|null> <data_json>
#   Prints one envelope object to stdout. Reads REPO from caller scope and
#   ENG_TEAM from the environment. <data_json> must be a valid JSON value.
#   <window_days> may be an integer or the literal string "null".
emit_json() {
    local metric="$1" window="$2" data="$3"
    local team_arg="null"
    [[ -n "${ENG_TEAM:-}" ]] && team_arg="$ENG_TEAM"
    local generated
    generated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jq -n \
        --arg metric "$metric" \
        --arg repo "${REPO:-}" \
        --arg team "$team_arg" \
        --arg generated "$generated" \
        --argjson window "$window" \
        --argjson data "$data" \
        '{
            metric: $metric,
            repo: $repo,
            team: (if $team == "null" then null else $team end),
            window_days: $window,
            generated_at: $generated,
            data: $data
        }'
}

# json_error <code> <message>
#   Prints one error object to stdout and exits non-zero.
json_error() {
    local code="$1" message="$2"
    jq -n --arg code "$code" --arg message "$message" \
        '{ error: $message, code: $code }'
    exit 1
}

# json_preflight
#   Validates required tooling for JSON mode. Call ONLY when JSON=true.
#   Emits a json_error and exits on failure.
json_preflight() {
    command -v jq  >/dev/null 2>&1 || json_error DEP_MISSING "jq is not installed"
    command -v gh  >/dev/null 2>&1 || json_error DEP_MISSING "gh (GitHub CLI) is not installed"
    gh auth status >/dev/null 2>&1 || json_error AUTH "gh is not authenticated"
}

# ── Parallel per-PR fetch helper ─────────────────────────────────────
# The metrics that fetch per-PR detail (lottery-factor, contributor-patterns,
# review-time, …) make one `gh api` call per PR. Run them concurrently with
# xargs -P for a large speedup on big repos, without hammering GitHub's
# secondary rate limits.
#
# ENG_CONCURRENCY controls the degree of parallelism (default 8).
eng_concurrency() {
    local n="${ENG_CONCURRENCY:-8}"
    # guard against non-numeric / zero
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=8
    printf '%s' "$n"
}

# parallel_map <worker_fn> < input
#   Reads input lines on stdin and runs the shell function <worker_fn> for each,
#   up to ENG_CONCURRENCY at a time, with the line passed as "$1".
#
#   Implementation note: we serialize the function with `declare -f` into a temp
#   file that each xargs worker sources. This is deliberate — `export -f` does
#   NOT reliably reach the bash that xargs spawns (the BASH_FUNC_* env entries
#   are not always present), so the obvious `bash -c 'fn "$1"'` silently fails
#   with "command not found". Sourcing a serialized definition is robust.
#
#   The function may use jq's `--arg`/`--argjson` exactly as in the serial
#   version (no shell-into-jq interpolation pitfalls). Any plain env vars it
#   needs (e.g. REPO) must be exported by the caller.
#
#   Output from all workers is concatenated to stdout. Workers must emit only
#   whole lines shorter than the pipe buffer (PIPE_BUF, >=512B everywhere) so
#   concurrent appends don't interleave — true for the short records these
#   scripts produce.
#
#   IMPORTANT — field separator: `xargs -I{}` normalizes whitespace (it turns a
#   tab inside the replacement into a space), so multi-field input lines must
#   NOT be tab/space separated. Use `|` between fields (PR numbers are integers
#   and GitHub logins cannot contain `|`, so it is safe here).
#
# Usage:
#   fetch_one() { local n="${1%%|*}" a="${1#*|}"; gh api ... | jq ...; }
#   export REPO
#   printf '%s\n' "${items[@]}" | parallel_map fetch_one   # lines: "num|author"
parallel_map() {
    local worker="$1"
    local jobs; jobs=$(eng_concurrency)
    local fnfile; fnfile=$(mktemp)
    # Serialize the function definition + an invocation that takes "$1".
    declare -f "$worker" > "$fnfile"
    printf '%s "$1"\n' "$worker" >> "$fnfile"
    xargs -P "$jobs" -I {} bash "$fnfile" {}
    rm -f "$fnfile"
}
