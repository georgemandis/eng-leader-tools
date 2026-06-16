# JSON Output Contract

Most `engleader.tools` metric commands support a `--json` flag that emits a
single, machine-readable JSON object to stdout. This is the data contract
consumed by downstream tools (e.g. the Engleader Reports macOS app).

`--json` reuses the same computed values as the human-readable table/CSV
output — it is a different final formatter over the same numbers, not a
separate computation.

## Envelope

Every `--json` invocation prints exactly one object with this shape:

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

| Field          | Type            | Notes |
|----------------|-----------------|-------|
| `metric`       | string          | Stable metric id (see table below). |
| `repo`         | string          | `owner/repo`. |
| `team`         | string \| null  | `null` unless `ENG_TEAM` is set. |
| `window_days`  | int \| null     | The lookback window in days, or `null` for commands whose argument is a PR count or which operate on currently-open PRs. |
| `generated_at` | string          | ISO 8601 UTC timestamp. |
| `data`         | object          | Metric-specific payload (see below). |

In `--json` mode, stdout contains **only** the envelope — no status lines, no
table, no CSV. If both `--csv` and `--json` are passed, `--json` wins.

## Errors

On a dependency, auth, or argument failure in `--json` mode, the command prints
an error object and exits non-zero:

```json
{ "error": "gh is not authenticated", "code": "AUTH" }
```

Codes: `AUTH`, `NOT_FOUND`, `RATE_LIMIT`, `BAD_ARGS`, `DEP_MISSING`, `UNKNOWN`.

## Metrics

| Command | `metric` | `window_days` | `data` fields |
|---------|----------|---------------|---------------|
| `lead-time` | `lead-time` | days arg | `count`, `avg_seconds`, `prs[]` (`number`, `author`, `lead_time_seconds`, `created_at`, `merged_at`, `url`) |
| `review-time` | `review-time` | PR count | `count`, `avg_time_to_first_review_seconds`, `avg_time_to_merge_seconds`, `prs[]` (`number`, `title`, `author`, `time_to_first_review_seconds` (null if unreviewed), `time_to_merge_seconds`, `url`) |
| `pr-size` | `pr-size` | null | `sample_count`, `buckets[]` (`size`, `count`, `avg_review_seconds`), `total_additions`, `total_deletions` |
| `stale-prs` | `stale-prs` | null | `open_count`, `buckets[]` (`label`, `count`), `prs[]` (`number`, `author`, `age_days`, `is_draft`, `title`, `url`) |
| `files-per-pr` | `files-per-pr` | null | `count`, `avg_files`, `median_files`, `prs[]` (`number`, `author`, `files_changed`, `url`) |
| `deploy-frequency` | `deploy-frequency` | days arg | `window_days`, `deploy_count`, `deploys_per_day`, `series[]` (`date`, `count`) |
| `change-failure-rate` | `change-failure-rate` | days arg | `total_merged`, `failure_count`, `failure_rate`, `failures[]` (`number`, `reason`, `url`) |
| `review-load` | `review-load` | null | `total_reviews`, `reviewers[]` (`login`, `reviews`, `share`), `top_share` |
| `lottery-factor` | `lottery-factor` | null | `files[]` (`path`, `top_author`, `top_author_share`, `total_changes`), `concentrated_count` |
| `contributor-patterns` | `contributor-patterns` | null | `contributors[]` (`login`, `pr_count`, `avg_files_per_pr`) |
| `code-churn` | `code-churn` | days arg | `files[]` (`path`, `change_count`), `hotspot_count` |
| `dependency-changes` | `dependency-changes` | days arg | `manifest_changes[]` (`file`, `change_count`), `total_dependency_prs` |

### Field notes

- `*_seconds` values are integers. Rates and shares (`failure_rate`,
  `deploys_per_day`, `share`, `top_share`, `top_author_share`) are floats in
  `0..1` (or per-day for `deploys_per_day`).
- `contributor-patterns.avg_files_per_pr` is the average number of **files**
  changed per PR by that contributor — the script does not fetch line-level
  diff stats, so this is a file count, not a line count.
- `code-churn.files[]` intentionally has **no** `authors` field — the script
  tracks filenames only, not per-file authorship.
- Empty result sets return a valid envelope with zeroed/empty `data` and exit 0
  (not an error).

## Requirements

`gh` (authenticated) and `jq`. `--json` mode runs a preflight check and emits a
`DEP_MISSING` / `AUTH` error envelope if either is unavailable.
