# --json Output Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--json` output mode (plus a structured JSON error envelope) to the 12 `engleader.tools` scripts the Engleader Reports macOS app consumes, establishing a stable machine-readable data contract.

**Architecture:** A shared `emit_json` / `json_error` helper pair lives in `src/_common.sh`. Each script keeps its existing table/CSV code paths untouched; when `--json` is passed, the script collects the same computed numbers it already produces into a `jq`-built `data` object and prints a single envelope via `emit_json`. Status chatter (`Fetching …`) is suppressed in JSON mode. No test framework is added — this repo verifies by eye, and each task ends with a concrete `jq` verification command.

**Tech Stack:** Bash, `jq` 1.8+, GitHub CLI (`gh`). No new dependencies.

---

## Conventions used in every script

These are the rules each per-script task follows. They are stated once here and referenced — but each task still shows its own complete code.

1. **Flag parsing:** add `--json) JSON=true ;;` alongside the existing `--csv` case, and strip `--json` from positional args exactly like `--csv` is stripped.
2. **Quiet mode:** treat JSON as implying quiet. Guard every human-facing status `echo` (e.g. `Fetching …`) with `[[ "$JSON" == "false" ]]`. The existing guards are usually `[[ "$CSV" == "false" ]]` — widen them to `[[ "$CSV" == "false" && "$JSON" == "false" ]]`.
3. **Mutual exclusion:** if both `--csv` and `--json` are passed, JSON wins (check `JSON` first).
4. **Empty results:** when a script currently prints "No PRs …" and `exit 0`, in JSON mode instead emit a valid envelope with an empty/zeroed `data` and `exit 0` — never print prose to stdout in JSON mode.
5. **Errors:** dependency/auth/arg failures call `json_error <code> <message>` (prints JSON to stdout, exits non-zero) **only when `JSON=true`**; otherwise keep the existing human error behavior.
6. **One object only:** in JSON mode stdout must contain exactly one JSON object — the envelope. No table, no CSV header, no trailing summary line.

### Envelope shape

```json
{
  "metric": "lead-time",
  "repo": "owner/repo",
  "team": "frontend-team",
  "window_days": 30,
  "generated_at": "2026-06-15T12:00:00Z",
  "data": { }
}
```

`team` is `null` when no team filter is active. `window_days` is `null` for scripts that take a count or no window instead of days (noted per task).

### Error shape

```json
{ "error": "gh is not authenticated", "code": "AUTH" }
```

Codes: `AUTH`, `NOT_FOUND`, `RATE_LIMIT`, `BAD_ARGS`, `DEP_MISSING`, `UNKNOWN`.

---

## Task 1: Shared JSON helpers in `_common.sh`

**Files:**
- Modify: `src/_common.sh` (append helpers at end)

- [ ] **Step 1: Add the `emit_json` and `json_error` helpers**

Append to the end of `src/_common.sh`:

```bash
# ── JSON output helpers ──────────────────────────────────────────────
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
```

- [ ] **Step 2: Verify `emit_json` produces a valid envelope**

Run:
```bash
cd /Users/georgemandis/Projects/engleader.tools/engleader-tools-scripts
REPO="octo/demo" ENG_TEAM="" bash -c 'source src/_common.sh; emit_json "demo" 30 "{\"x\":1}"' | jq .
```
Expected: a JSON object with `metric:"demo"`, `repo:"octo/demo"`, `team:null`, `window_days:30`, a `generated_at` ISO string, and `data:{"x":1}`. `jq .` exits 0 (valid JSON).

- [ ] **Step 3: Verify `team` is populated when `ENG_TEAM` is set**

Run:
```bash
REPO="octo/demo" ENG_TEAM="frontend" bash -c 'source src/_common.sh; emit_json "demo" null "{}"' | jq '.team, .window_days'
```
Expected: `"frontend"` then `null`.

- [ ] **Step 4: Verify `json_error` shape and exit code**

Run:
```bash
bash -c 'source src/_common.sh; json_error AUTH "gh is not authenticated"'; echo "exit=$?"
```
Expected: `{ "error": "gh is not authenticated", "code": "AUTH" }` followed by `exit=1`.

- [ ] **Step 5: Commit**

```bash
git add src/_common.sh
git commit -m "feat(json): add emit_json and json_error helpers to _common.sh"
```

---

## Task 2: Dependency + auth preflight helper

A shared check so every script can fail with a clean JSON error when `gh`/`jq` are missing or `gh` is unauthenticated, instead of a raw stack trace.

**Files:**
- Modify: `src/_common.sh` (append helper)

- [ ] **Step 1: Add `json_preflight`**

Append to `src/_common.sh`:

```bash
# json_preflight
#   Validates required tooling for JSON mode. Call ONLY when JSON=true,
#   AFTER sourcing _common.sh. Emits a json_error and exits on failure.
json_preflight() {
    command -v jq  >/dev/null 2>&1 || json_error DEP_MISSING "jq is not installed"
    command -v gh  >/dev/null 2>&1 || json_error DEP_MISSING "gh (GitHub CLI) is not installed"
    gh auth status >/dev/null 2>&1 || json_error AUTH "gh is not authenticated"
}
```

- [ ] **Step 2: Verify preflight passes in a healthy environment**

Run:
```bash
bash -c 'source src/_common.sh; json_preflight && echo OK'
```
Expected: `OK` (assuming `gh` is installed and authenticated on this machine).

- [ ] **Step 3: Verify preflight fails cleanly when a dep is "missing"**

Run (simulate missing jq by emptying PATH for the probe):
```bash
bash -c 'source src/_common.sh; PATH="/nonexistent" json_preflight'; echo "exit=$?"
```
Expected: a JSON object `{ "error": "jq is not installed", "code": "DEP_MISSING" }` and `exit=1`.

- [ ] **Step 4: Commit**

```bash
git add src/_common.sh
git commit -m "feat(json): add json_preflight dependency/auth check"
```

---

## Task 3: Convert `leadtimetochange.sh` (the reference pattern)

This is the canonical conversion. Later tasks replicate this shape. Lead-time produces a per-PR list and an average; the `data` object carries summary stats plus a per-PR series.

**Files:**
- Modify: `src/leadtimetochange.sh`

Target `data` shape:
```json
{
  "count": 42,
  "avg_seconds": 207360,
  "prs": [
    { "number": 123, "author": "alice", "lead_time_seconds": 164160,
      "created_at": "2026-05-01T10:00:00Z", "merged_at": "2026-05-03T07:36:00Z",
      "url": "https://github.com/owner/repo/pull/123" }
  ]
}
```

- [ ] **Step 1: Add `JSON` flag parsing**

In `src/leadtimetochange.sh`, change the flag loop (currently lines ~36-49) to also recognize `--json`:

```bash
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
```

- [ ] **Step 2: Preflight + quiet the status echo**

Immediately after `[[ "$_REPO_FROM_ARG" == true ]] && shift` (line ~54), add:

```bash
[[ "$JSON" == "true" ]] && json_preflight
```

Then widen the status-echo guard (currently `if [[ "$CSV" == "false" ]]; then` around line 79) to:

```bash
if [[ "$CSV" == "false" && "$JSON" == "false" ]]; then
```

- [ ] **Step 3: Handle the empty-result case in JSON mode**

Replace the empty-result block (currently lines ~117-120):

```bash
if [[ -z "$PR_JSON" ]]; then
  echo "No PRs merged in the last $DAYS days." >&2
  exit 0
fi
```

with:

```bash
if [[ -z "$PR_JSON" ]]; then
  if [[ "$JSON" == "true" ]]; then
    emit_json "lead-time" "$DAYS" '{"count":0,"avg_seconds":0,"prs":[]}'
    exit 0
  fi
  echo "No PRs merged in the last $DAYS days." >&2
  exit 0
fi
```

- [ ] **Step 4: Collect PR records and skip table/CSV printing in JSON mode**

Replace the header-printing block (currently lines ~126-131):

```bash
if [[ "$CSV" == "true" ]]; then
  echo "PR,Author,Lead Time,Lead Time (seconds),Created,Merged,URL"
else
  printf "\n%-6s  %-18s  %-15s  %-20s  %-20s  %s\n" "PR#" "Author" "Lead Time" "Created" "Merged" "URL"
  printf "%s\n" "--------------------------------------------------------------------------------------------------------------"
fi
```

with:

```bash
if [[ "$JSON" == "true" ]]; then
  : # collect into pr_records array below; no header
elif [[ "$CSV" == "true" ]]; then
  echo "PR,Author,Lead Time,Lead Time (seconds),Created,Merged,URL"
else
  printf "\n%-6s  %-18s  %-15s  %-20s  %-20s  %s\n" "PR#" "Author" "Lead Time" "Created" "Merged" "URL"
  printf "%s\n" "--------------------------------------------------------------------------------------------------------------"
fi

pr_records=()
```

- [ ] **Step 5: Build a JSON record per PR inside the loop**

In the per-PR loop, replace the print block (currently lines ~148-152):

```bash
  if [[ "$CSV" == "true" ]]; then
    printf "%s,%s,%s,%s,%s,%s,%s\n" "$num" "$author" "$normalized_time" "$delta" "$created" "$merged" "$pr_link"
  else
    printf "#%-5s  %-18s  %-15s  %-20s  %-20s  %s\n" "$num" "$author" "$normalized_time" "$created" "$merged" "$pr_link"
  fi
```

with:

```bash
  if [[ "$JSON" == "true" ]]; then
    pr_records+=("$(jq -n \
      --argjson number "$num" \
      --arg author "$author" \
      --argjson lead "$delta" \
      --arg created "$created" \
      --arg merged "$merged" \
      --arg url "$pr_link" \
      '{number:$number, author:$author, lead_time_seconds:$lead, created_at:$created, merged_at:$merged, url:$url}')")
  elif [[ "$CSV" == "true" ]]; then
    printf "%s,%s,%s,%s,%s,%s,%s\n" "$num" "$author" "$normalized_time" "$delta" "$created" "$merged" "$pr_link"
  else
    printf "#%-5s  %-18s  %-15s  %-20s  %-20s  %s\n" "$num" "$author" "$normalized_time" "$created" "$merged" "$pr_link"
  fi
```

- [ ] **Step 6: Emit the envelope after the loop**

Replace the trailing summary block (currently lines ~158-161):

```bash
if (( count > 0 )) && [[ "$CSV" == "false" ]]; then
  avg_sec=$(( total_seconds / count ))
  avg_time=$(format_time "$avg_sec")
  printf "\nAnalyzed %d PR(s) • Average lead time: %s\n" "$count" "$avg_time"
fi
```

with:

```bash
if [[ "$JSON" == "true" ]]; then
  avg_sec=0
  (( count > 0 )) && avg_sec=$(( total_seconds / count ))
  prs_array=$(printf '%s\n' "${pr_records[@]+"${pr_records[@]}"}" | jq -s '.')
  data=$(jq -n \
    --argjson count "$count" \
    --argjson avg "$avg_sec" \
    --argjson prs "$prs_array" \
    '{count:$count, avg_seconds:$avg, prs:$prs}')
  emit_json "lead-time" "$DAYS" "$data"
elif (( count > 0 )) && [[ "$CSV" == "false" ]]; then
  avg_sec=$(( total_seconds / count ))
  avg_time=$(format_time "$avg_sec")
  printf "\nAnalyzed %d PR(s) • Average lead time: %s\n" "$count" "$avg_time"
fi
```

Note: `printf '%s\n' "${pr_records[@]+...}" | jq -s '.'` yields `[]` when the array is empty (empty input to `jq -s` is `[]`), which is correct.

- [ ] **Step 7: Verify valid JSON with expected fields (live, small window)**

Run against a real repo you have access to (substitute one):
```bash
./src/leadtimetochange.sh OWNER/REPO 30 --json | jq '{metric, repo, window_days, count: .data.count, first: .data.prs[0]}'
```
Expected: valid JSON; `metric` is `"lead-time"`, `window_days` is `30`, `data.count` is an integer, and `data.prs[0]` (if any) has `number`, `author`, `lead_time_seconds`, `created_at`, `merged_at`, `url`.

- [ ] **Step 8: Verify exactly one object and no stray stdout**

Run:
```bash
./src/leadtimetochange.sh OWNER/REPO 30 --json | jq -s 'length'
```
Expected: `1` (stdout is a single JSON object — confirms no status chatter or table leaked into stdout).

- [ ] **Step 9: Verify the table/CSV paths still work unchanged**

Run:
```bash
./src/leadtimetochange.sh OWNER/REPO 30 | head -3
./src/leadtimetochange.sh OWNER/REPO 30 --csv | head -2
```
Expected: the original table header and the original CSV header — unchanged behavior.

- [ ] **Step 10: Commit**

```bash
git add src/leadtimetochange.sh
git commit -m "feat(json): add --json output to lead-time"
```

---

## Tasks 4–14: Replicate the pattern across the remaining 11 scripts

Each task below follows the **same 10-step shape as Task 3**. **Before implementing any task in this group, re-read Task 3 in full** — it is the complete, authoritative pattern (flag parsing, `json_preflight`, widening the status-echo guards to `[[ "$CSV" == "false" && "$JSON" == "false" ]]`, the empty-result envelope, collecting `pr_records` with `jq -n`, and emitting via `emit_json` with `printf '%s\n' "${pr_records[@]+...}" | jq -s '.'`). Apply those exact idioms here; only the per-script specifics differ.

For each task, the only things that change from Task 3 are: (a) the `metric` string passed to `emit_json`, (b) whether `window_days` is the days arg or `null`, and (c) the `data` shape. Each task gives all three plus any script-specific quirk. Every task ends with: the `jq` verify command shown, a check that the table/CSV paths are unchanged (`./src/<script> OWNER/REPO ... | head -3`), and a commit.

> When implementing, open the target script, locate its flag loop / status echos / empty-result block / final summary (the structure mirrors lead-time), and apply the Task 3 transformation producing the `data` shape given. Build the `data` object with `jq -n --argjson …` exactly as Task 3 Step 6 does.

---

### Task 4: `pr-review-time.sh`

**metric:** `review-time` · **window_days:** the `days` arg · **script note:** computes time-to-first-review and time-to-merge per PR.

`data` shape:
```json
{
  "count": 30,
  "avg_time_to_first_review_seconds": 28800,
  "avg_time_to_merge_seconds": 172800,
  "prs": [
    { "number": 12, "author": "alice",
      "time_to_first_review_seconds": 14400,
      "time_to_merge_seconds": 90000,
      "url": "https://github.com/owner/repo/pull/12" }
  ]
}
```
For PRs with no review, set `time_to_first_review_seconds` to `null`. Average over reviewed PRs only; if none reviewed, `avg_time_to_first_review_seconds` is `0`.

Verify:
```bash
./src/pr-review-time.sh OWNER/REPO 30 --json | jq '{metric, count:.data.count, avg1:.data.avg_time_to_first_review_seconds}'
```
Commit: `feat(json): add --json output to review-time`

---

### Task 5: `pr-size-distribution.sh`

**metric:** `pr-size` · **window_days:** `null` (this script takes a PR **count**, not days — pass the count through as a separate `data` field) · **script note:** buckets PRs XS/S/M/L/XL and correlates review time. Uses `declare -A size_counts`.

`data` shape:
```json
{
  "sample_count": 50,
  "buckets": [
    { "size": "XS", "count": 12, "avg_review_seconds": 3600 },
    { "size": "S",  "count": 18, "avg_review_seconds": 7200 },
    { "size": "M",  "count": 11, "avg_review_seconds": 14400 },
    { "size": "L",  "count": 6,  "avg_review_seconds": 28800 },
    { "size": "XL", "count": 3,  "avg_review_seconds": 90000 }
  ],
  "total_additions": 4210,
  "total_deletions": 1180
}
```
Build `buckets` by iterating the fixed order `XS S M L XL` over the associative arrays (`size_counts`, `size_total_times`) the script already maintains; compute `avg_review_seconds` as `size_total_times[k] / size_counts[k]` (0 when count is 0). The script's per-PR loop uses `jq -r '.[] | @base64'`; leave that intact and accumulate the same counters — only the final output branch changes.

Verify:
```bash
./src/pr-size-distribution.sh OWNER/REPO 50 --json | jq '.data.buckets'
```
Commit: `feat(json): add --json output to pr-size`

---

### Task 6: `stale-prs.sh`

**metric:** `stale-prs` · **window_days:** `null` (operates on currently-open PRs; if it takes a staleness-threshold arg, pass it as `data.threshold_days`).

`data` shape:
```json
{
  "open_count": 14,
  "buckets": [
    { "label": "0-7d",   "count": 5 },
    { "label": "8-30d",  "count": 6 },
    { "label": "31-90d", "count": 2 },
    { "label": "90d+",   "count": 1 }
  ],
  "prs": [
    { "number": 7, "author": "bob", "age_days": 41,
      "title": "Refactor auth", "url": "https://github.com/owner/repo/pull/7" }
  ]
}
```
Use the same bucket boundaries the script already prints (match whatever the existing grouping is; adjust labels to the script's real thresholds if they differ).

Verify:
```bash
./src/stale-prs.sh OWNER/REPO --json | jq '{open:.data.open_count, buckets:.data.buckets}'
```
Commit: `feat(json): add --json output to stale-prs`

---

### Task 7: `files-per-pr.sh`

**metric:** `files-per-pr` · **window_days:** the window arg if present, else `null`.

`data` shape:
```json
{
  "count": 40,
  "avg_files": 4.7,
  "median_files": 3,
  "prs": [
    { "number": 9, "author": "carol", "files_changed": 6,
      "url": "https://github.com/owner/repo/pull/9" }
  ]
}
```
`avg_files` is a float (use `jq` arithmetic or compute with awk and pass via `--argjson`).

Verify:
```bash
./src/files-per-pr.sh OWNER/REPO --json | jq '{avg:.data.avg_files, count:.data.count}'
```
Commit: `feat(json): add --json output to files-per-pr`

---

### Task 8: `deployment-frequency.sh`

**metric:** `deploy-frequency` · **window_days:** the `days` arg.

`data` shape:
```json
{
  "window_days": 30,
  "deploy_count": 22,
  "deploys_per_day": 0.73,
  "series": [
    { "date": "2026-05-01", "count": 1 }
  ]
}
```
`series` is per-day deploy counts (use the dates the script already derives). `deploys_per_day` is `deploy_count / window_days` as a float.

Verify:
```bash
./src/deployment-frequency.sh OWNER/REPO 30 --json | jq '{count:.data.deploy_count, perday:.data.deploys_per_day}'
```
Commit: `feat(json): add --json output to deploy-frequency`

---

### Task 9: `changefailurerate.sh`

**metric:** `change-failure-rate` · **window_days:** the `days` arg.

`data` shape:
```json
{
  "total_merged": 80,
  "failure_count": 6,
  "failure_rate": 0.075,
  "failures": [
    { "number": 55, "reason": "hotfix", "url": "https://github.com/owner/repo/pull/55" }
  ]
}
```
`failure_rate` is `failure_count / total_merged` as a float (0 when `total_merged` is 0). `reason` is whatever the script uses to flag a rollback/hotfix.

Verify:
```bash
./src/changefailurerate.sh OWNER/REPO 30 --json | jq '{rate:.data.failure_rate, n:.data.total_merged}'
```
Commit: `feat(json): add --json output to change-failure-rate`

---

### Task 10: `review-load.sh`

**metric:** `review-load` · **window_days:** the `days` arg.

`data` shape:
```json
{
  "window_days": 30,
  "total_reviews": 120,
  "reviewers": [
    { "login": "alice", "reviews": 70, "share": 0.583 },
    { "login": "bob",   "reviews": 50, "share": 0.417 }
  ],
  "top_share": 0.583
}
```
`share` is per-reviewer fraction of `total_reviews`; `top_share` is the max share (the concentration signal the InsightEngine uses). Sort `reviewers` by `reviews` descending.

Verify:
```bash
./src/review-load.sh OWNER/REPO 30 --json | jq '{top:.data.top_share, reviewers:.data.reviewers}'
```
Commit: `feat(json): add --json output to review-load`

---

### Task 11: `lottery-factor.sh`

**metric:** `lottery-factor` · **window_days:** the window arg if present, else `null`.

`data` shape:
```json
{
  "files": [
    { "path": "src/auth.ts", "top_author": "alice",
      "top_author_share": 0.82, "total_changes": 50 }
  ],
  "concentrated_count": 3
}
```
`concentrated_count` = number of files whose `top_author_share > 0.5` (the InsightEngine threshold). Include the files the script already reports; sort by `top_author_share` descending.

Verify:
```bash
./src/lottery-factor.sh OWNER/REPO --json | jq '{concentrated:.data.concentrated_count, first:.data.files[0]}'
```
Commit: `feat(json): add --json output to lottery-factor`

---

### Task 12: `contributor-file-patterns.sh`

**metric:** `contributor-patterns` · **window_days:** the window arg if present, else `null`.

`data` shape:
```json
{
  "contributors": [
    { "login": "alice", "pr_count": 30,
      "avg_pr_size_lines": 210, "size_profile": "M" }
  ]
}
```
Map the per-contributor stats the script computes; `size_profile` is the dominant bucket label if the script derives one, else omit that key.

Verify:
```bash
./src/contributor-file-patterns.sh OWNER/REPO --json | jq '.data.contributors[0]'
```
Commit: `feat(json): add --json output to contributor-patterns`

---

### Task 13: `code-churn.sh`

**metric:** `code-churn` · **window_days:** the window arg if present, else `null` · **script note:** this script has no `--csv` mode today — add `--json` following the same pattern; there is no CSV branch to widen, only the table/status output to guard with `[[ "$JSON" == "false" ]]`.

`data` shape:
```json
{
  "files": [
    { "path": "src/api.ts", "change_count": 37, "authors": 4 }
  ],
  "hotspot_count": 10
}
```
`hotspot_count` = number of files in the reported set. Sort by `change_count` descending.

Verify:
```bash
./src/code-churn.sh OWNER/REPO --json | jq '{hotspots:.data.hotspot_count, first:.data.files[0]}'
```
Commit: `feat(json): add --json output to code-churn`

---

### Task 14: `dependency-changes.sh`

**metric:** `dependency-changes` · **window_days:** the window arg if present, else `null` · **script note:** no `--csv` mode today — same as Task 13, only guard the table/status output.

`data` shape:
```json
{
  "manifest_changes": [
    { "file": "package.json", "change_count": 8 }
  ],
  "total_dependency_prs": 12
}
```

Verify:
```bash
./src/dependency-changes.sh OWNER/REPO --json | jq '{prs:.data.total_dependency_prs, files:.data.manifest_changes}'
```
Commit: `feat(json): add --json output to dependency-changes`

---

## Task 15: Document the contract

**Files:**
- Modify: `README.md` (add a "JSON output" subsection under Usage)
- Create: `docs/json-contract.md`

- [ ] **Step 1: Write `docs/json-contract.md`**

Document the envelope shape, the error shape and codes, and a table mapping each of the 12 metrics to its `metric` string and `data` fields (copy the shapes from the tasks above). State that `--json` reuses the same computed values as the table/CSV output and is the contract the Engleader Reports app depends on.

- [ ] **Step 2: Add a short README pointer**

Under Usage in `README.md`, add:

```markdown
### JSON output

Most metric commands support `--json` for machine-readable output:

    eng lead-time my-org/my-repo 30 --json

Output is a single JSON envelope (`metric`, `repo`, `team`, `window_days`,
`generated_at`, `data`). Errors are emitted as `{ "error", "code" }` with a
non-zero exit. See `docs/json-contract.md` for the full contract.
```

- [ ] **Step 3: Verify the README example runs**

Run:
```bash
eng lead-time OWNER/REPO 30 --json | jq -e '.metric == "lead-time"' && echo OK
```
Expected: `true` then `OK`.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/json-contract.md
git commit -m "docs(json): document the --json output contract"
```

---

## Task 16: Update help text and shell completion

**Files:**
- Modify: each of the 12 scripts' `usage()` (add `--json` line next to `--csv`)
- Modify: `eng` (if it lists per-command flags or has completion hints for `--csv`)

- [ ] **Step 1: Add `--json` to each script's `usage()`**

In every converted script, add under the existing `--csv` help line:

```
  --json       Output as a single JSON envelope (machine-readable)
```

- [ ] **Step 2: Check `eng` for completion entries**

Run:
```bash
grep -n '\-\-csv' eng
```
If `--csv` appears in completion/help in `eng`, add a parallel `--json` entry at each location. If it does not appear, no change needed.

- [ ] **Step 3: Verify help shows `--json`**

Run:
```bash
./src/leadtimetochange.sh --help | grep -- --json
```
Expected: the `--json` help line prints.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs(json): add --json to help text and completion"
```

---

## Self-review notes

- **Coverage:** all 12 spec scripts have a task (Tasks 3–14): lead-time, review-time, pr-size, stale-prs, files-per-pr, deploy-frequency, change-failure-rate, review-load, lottery-factor, contributor-patterns, code-churn, dependency-changes. Helpers (Tasks 1–2), docs (15), help/completion (16) complete the contract.
- **`code-churn` and `dependency-changes`** are flagged as having no existing `--csv` branch, so their conversion only guards the table/status output — called out in Tasks 13–14.
- **Quiet mode** is enforced uniformly via the convention block + per-task status-echo guards, ensuring exactly one JSON object on stdout (verified in Task 3 Step 8).
- **`window_days` is `null`** for count-based or open-PR scripts (pr-size, stale-prs, and any without a days arg), noted per task.
- **No test framework** is introduced, matching the repo's existing convention (zero prior tests, two shipped releases); every task ends with a concrete `jq` verification command instead.
