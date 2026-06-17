# engleader MCP server

Exposes `eng` metric commands as MCP tools so AI agents can query engineering-leadership metrics directly.

**Agent support:** Claude Code and Cursor are fully supported and verified. VS Code, Gemini, Codex, Windsurf, and OpenCode are best-effort — their MCP config schemas vary, so the installer's entry may need a manual tweak (Codex, for example, uses a TOML config rather than the `.mcpServers` JSON key the installer writes).

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

To remove it again:

```bash
eng mcp uninstall            # interactive
eng mcp uninstall --all      # remove from every agent that has it
eng mcp uninstall --dry-run  # show what would be removed, write nothing
```

## Manual (Claude Code)

```bash
claude mcp add engleader -s user -- bun run /path/to/engleader-tools-scripts/mcp/index.ts
```

## Configuration

- `ENG_BIN` — path to the `eng` binary if it isn't on PATH.

## Tools

13 tools, one per metric: `eng_lead_time`, `eng_change_failure_rate`, `eng_deploy_frequency`, `eng_review_time`, `eng_pr_size`, `eng_files_per_pr`, `eng_stale_prs`, `eng_review_load`, `eng_code_churn`, `eng_contributor_patterns`, `eng_lottery_factor`, `eng_dependency_changes`, `eng_pull_discussion`. Each accepts `repo` (owner/repo); metric tools return the JSON envelope, `eng_pull_discussion` returns structured text.
