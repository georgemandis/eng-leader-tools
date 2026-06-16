# engleader MCP server

Exposes `eng` metric commands as MCP tools so AI agents (Claude Code, Cursor, VS Code, Gemini, Codex, Windsurf, OpenCode) can query engineering-leadership metrics directly.

## Prerequisites

- [`eng`](../README.md) installed and on your PATH (the server shells out to it)
- [Bun](https://bun.sh)
- An authenticated `gh` (the metrics hit the GitHub API)

## Install

The easiest path is the bundled installer, which detects your agents and wires them up:

```bash
eng mcp install            # interactive
eng mcp install --all      # all detected agents
eng mcp install --dry-run  # show what would change, write nothing
```

## Manual (Claude Code)

```bash
claude mcp add engleader -s user -- bun run /path/to/engleader-tools-scripts/mcp/index.ts
```

## Configuration

- `ENG_BIN` — path to the `eng` binary if it isn't on PATH.

## Tools

13 tools, one per metric: `eng_lead_time`, `eng_change_failure_rate`, `eng_deploy_frequency`, `eng_review_time`, `eng_pr_size`, `eng_files_per_pr`, `eng_stale_prs`, `eng_review_load`, `eng_code_churn`, `eng_contributor_patterns`, `eng_lottery_factor`, `eng_dependency_changes`, `eng_pull_discussion`. Each accepts `repo` (owner/repo); metric tools return the JSON envelope, `eng_pull_discussion` returns structured text.
