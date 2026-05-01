# eng-leader-tools/scripts

A collection of bash scripts for engineering leadership metrics and team health analysis. Built on the GitHub CLI (`gh`) and `jq`, these scripts give you quick, terminal-friendly insights into how your team ships code — inspired by DORA metrics and practical eng management needs.

## Prerequisites

- [GitHub CLI (`gh`)](https://cli.github.com/) — authenticated
- [jq](https://jqlang.github.io/jq/)
- macOS or Linux (date handling is cross-platform)
- [llm](https://github.com/simonw/llm) — optional, only needed for `analyze-discussion.sh`

## Scripts

### DORA Metrics

| Script | Description |
|--------|-------------|
| `leadtimetochange.sh` | Average time from PR creation to merge for a repo |
| `leadtimetochange-user.sh` | Same as above, filtered to a specific contributor |
| `changefailurerate.sh` | Percentage of merged PRs flagged as rollbacks or hotfixes |
| `deployment-frequency.sh` | How often releases/tags ship, with DORA tier assessment |

### PR Health

| Script | Description |
|--------|-------------|
| `pr-review-time.sh` | Time to first review and time to merge, with process health indicators |
| `pr-size-distribution.sh` | Categorizes PRs by size (XS-XL) and correlates size with review time |
| `files-per-pr.sh` | Files changed per merged PR |
| `files-per-pr-live.sh` | Files changed per *open* PR, flags large ones needing review attention |
| `stale-prs.sh` | Open PRs grouped by age, highlights work that may need attention |
| `quick-reviews.sh` | Surfaces small open PRs (1-2 files) that haven't been approved yet |
| `review-load.sh` | How review work is distributed across team members |

### Codebase & Contributor Analysis

| Script | Description |
|--------|-------------|
| `code-churn.sh` | Identifies file hotspots — files changed repeatedly across PRs |
| `contributor-file-patterns.sh` | Shows per-contributor PR size patterns (focused vs. broad-scope) |
| `lottery-factor.sh` | Knowledge concentration risk — files where only 1-2 people have contributed |
| `dependency-changes.sh` | Tracks dependency update PRs, flags security updates, measures automation |
| `track-contributions.sh` | Tracks a user's review and comment activity across an org |

### Discussion Tools

| Script | Description |
|--------|-------------|
| `pull-discussion.sh` | Pulls full PR discussion (comments, reviews, files) as structured text |
| `analyze-discussion.sh` | Pipes PR discussion into an LLM for summarization |

## Usage

All scripts follow a consistent pattern:

```bash
# Most scripts take owner/repo as the first argument
./leadtimetochange.sh octocat/hello-world

# Many accept an optional lookback window in days (default varies by script)
./leadtimetochange.sh octocat/hello-world 90

# User-specific scripts add a username argument
./leadtimetochange-user.sh octocat/hello-world octocat 60

# All scripts support --help or -h
./leadtimetochange.sh --help
```

### Quick Reference

```bash
# How long do PRs stay open before merge? (last 30 days)
./leadtimetochange.sh my-org/my-repo

# How long do PRs stay open for a specific person?
./leadtimetochange-user.sh my-org/my-repo janedoe 60

# How responsive is code review?
./pr-review-time.sh my-org/my-repo 50

# Are PRs too big?
./pr-size-distribution.sh my-org/my-repo

# Any stale PRs that need attention?
./stale-prs.sh my-org/my-repo

# Who's doing the most code review?
./review-load.sh my-org/my-repo

# Where's the knowledge concentration risk?
./lottery-factor.sh my-org/my-repo

# What files keep getting changed?
./code-churn.sh my-org/my-repo 30 3

# How often do we deploy?
./deployment-frequency.sh my-org/my-repo 90

# What's our rollback/hotfix rate?
./changefailurerate.sh my-org/my-repo 30

# What has someone been reviewing lately?
./track-contributions.sh janedoe my-org 30 --verbose

# Any small PRs that need a quick review?
./quick-reviews.sh -o my-org -r my-repo

# Summarize a PR discussion with an LLM
./pull-discussion.sh my-org/my-repo 42 | ./analyze-discussion.sh
```

## CSV Output

Many scripts support `--csv` for machine-readable output, making it easy to pipe into spreadsheets, databases, or other tools:

```bash
./leadtimetochange.sh my-org/my-repo 90 --csv > lead-times.csv
./stale-prs.sh my-org/my-repo --csv > stale-prs.csv
./review-load.sh my-org/my-repo --csv > review-load.csv
./lottery-factor.sh my-org/my-repo --csv > lottery-factor.csv
```

Scripts with `--csv` support: `leadtimetochange.sh`, `leadtimetochange-user.sh`, `stale-prs.sh`, `review-load.sh`, `lottery-factor.sh`.

## Output

All scripts output formatted tables and summaries to stdout. Many include health assessments with color-coded indicators for quick interpretation. No files are written — pipe or redirect output as needed.
