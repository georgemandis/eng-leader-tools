# Roadmap

## Shipped

### Team Filtering (v0.2.0)
Filter metrics to GitHub Team members via `--team` flag. See README for usage.

## Under Consideration

### Team Filtering -- Additional Scripts

These scripts could support `--team` but have ambiguous filtering semantics that need design decisions:

- **`code-churn`**: What does team filtering mean for file hotspots?
  - Option A: Only show files changed by team members (person-centric)
  - Option B: Show all files but only count team member changes (file-centric, team-scoped)

- **`lottery-factor`**: What does team filtering mean for knowledge concentration?
  - Option A: Only count team member contributions -- "knowledge risk within my team"
  - Option B: Show files the team owns but count all contributors -- "files my team owns that have concentration risk"

- **`dependency-changes`**: Filter to dependency PRs authored by team members? Unclear if this is useful since dependency PRs are often automated (Dependabot, Renovate).

### Cross-Repo Aggregation
Run a command across all repos a team has access to and aggregate results. This is a fundamentally different operation from the current single-repo model and would need its own design.

### Generic Team Member Lists
Support non-GitHub-Teams definitions of a team (config file, comma-separated list of usernames). Useful for cross-org teams or when GitHub Teams don't match reporting structure. Users can already work around this by setting `ENG_TEAM_MEMBERS` directly.
