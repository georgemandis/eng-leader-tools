# engleader.tools

A collection of bash scripts for engineering leadership metrics and team health analysis. Built on the GitHub CLI (`gh`) and `jq`, these scripts give you quick, terminal-friendly insights into how your team ships code. Inspired by DORA metrics and practical eng management needs.

## Install

This project is intentionally small, portable and lean—it is literally just a folder full of bash files! It's based on actual scripts I've used in previous roles to better understand the engineering landscape. While I've tidied it up and made the whole suite available via package managers (more below), there's nothing stopping you from pulling down the repo and copying just the pieces you need.

### Homebrew (macOS/Linux)

```bash
brew tap georgemandis/tap
brew install eng-leader-tools
```

### Scoop (Windows)

```powershell
scoop bucket add georgemandis https://github.com/georgemandis/scoop-bucket
scoop install eng-leader-tools
```

### Manual

Clone the repo and add it to your PATH, or run the scripts directly.

## Prerequisites

- [GitHub CLI (`gh`)](https://cli.github.com/) — authenticated
- [jq](https://jqlang.github.io/jq/)
- macOS, Linux, or Windows (via Git Bash / WSL)
- [llm](https://github.com/simonw/llm) — optional, only needed for `analyze-discussion`

## Usage

Use the `eng` command to run any tool:

```bash
eng <command> [args...]
eng --help
eng lead-time --help
```

### DORA Metrics

| Command | Description |
|---------|-------------|
| `eng lead-time` | Average time from PR creation to merge for a repo |
| `eng lead-time-user` | Same as above, filtered to a specific contributor |
| `eng change-failure-rate` | Percentage of merged PRs flagged as rollbacks or hotfixes |
| `eng deploy-frequency` | How often releases/tags ship, with DORA tier assessment |

### PR Health

| Command | Description |
|---------|-------------|
| `eng review-time` | Time to first review and time to merge, with process health indicators |
| `eng pr-size` | Categorizes PRs by size (XS-XL) and correlates size with review time |
| `eng files-per-pr` | Files changed per merged PR |
| `eng files-per-pr-live` | Files changed per *open* PR, flags large ones needing review attention |
| `eng stale-prs` | Open PRs grouped by age, highlights work that may need attention |
| `eng quick-reviews` | Surfaces small open PRs (1-2 files) that haven't been approved yet |
| `eng review-load` | How review work is distributed across team members |

### Codebase & Contributor Analysis

| Command | Description |
|---------|-------------|
| `eng code-churn` | Identifies file hotspots — files changed repeatedly across PRs |
| `eng contributor-patterns` | Shows per-contributor PR size patterns (focused vs. broad-scope) |
| `eng lottery-factor` | Knowledge concentration risk — files where only 1-2 people have contributed |
| `eng dependency-changes` | Tracks dependency update PRs, flags security updates, measures automation |
| `eng contributions` | Tracks a user's review and comment activity across an org |

### Discussion Tools

| Command | Description |
|---------|-------------|
| `eng pull-discussion` | Pulls full PR discussion (comments, reviews, files) as structured text |
| `eng analyze-discussion` | Pipes PR discussion into an LLM for summarization |

## Quick Reference

```bash
# How long do PRs stay open before merge? (last 30 days)
eng lead-time my-org/my-repo

# How long do PRs stay open for a specific person?
eng lead-time-user my-org/my-repo janedoe 60

# How responsive is code review?
eng review-time my-org/my-repo 50

# Are PRs too big?
eng pr-size my-org/my-repo

# Any stale PRs that need attention?
eng stale-prs my-org/my-repo

# Who's doing the most code review?
eng review-load my-org/my-repo

# Where's the knowledge concentration risk?
eng lottery-factor my-org/my-repo

# What files keep getting changed?
eng code-churn my-org/my-repo 30 3

# How often do we deploy?
eng deploy-frequency my-org/my-repo 90

# What's our rollback/hotfix rate?
eng change-failure-rate my-org/my-repo 30

# What has someone been reviewing lately?
eng contributions janedoe my-org 30 --verbose

# Any small PRs that need a quick review?
eng quick-reviews -o my-org -r my-repo

# Summarize a PR discussion with an LLM
eng pull-discussion my-org/my-repo 42 | eng analyze-discussion
```

## CSV Output

Many commands support `--csv` for machine-readable output:

```bash
eng lead-time my-org/my-repo 90 --csv > lead-times.csv
eng stale-prs my-org/my-repo --csv > stale-prs.csv
eng review-load my-org/my-repo --csv > review-load.csv
eng lottery-factor my-org/my-repo --csv > lottery-factor.csv
```

## Shell Completions

```bash
# bash — add to ~/.bashrc
eval "$(eng --completions bash)"

# zsh — add to ~/.zshrc
eval "$(eng --completions zsh)"

# fish — persist to completions dir
eng --completions fish > ~/.config/fish/completions/eng.fish
```

## Output

All commands output formatted tables and summaries to stdout. Many include health assessments with color-coded indicators for quick interpretation. No files are written — pipe or redirect output as needed.

## Sponsor

If you find this project useful, please consider [sponsoring me](https://github.com/sponsors/georgemandis).

## License

MIT
