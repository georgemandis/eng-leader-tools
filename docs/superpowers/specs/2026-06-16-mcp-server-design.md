# MCP Server + `eng mcp` Installer Design

## Problem

The `eng` CLI exposes a suite of engineering-leadership metrics over the GitHub
API, and most metric commands already emit a stable, machine-readable JSON
envelope via `--json` (see [`docs/json-contract.md`](../../json-contract.md)).
But the only way to consume those metrics from an AI coding agent today is to
manually run shell commands and paste output. We want agents (Claude Code,
Cursor, VS Code/Copilot, Gemini CLI, Codex, Windsurf, OpenCode) to call these
metrics directly as tools.

The complementary [engsight](https://engsight) project ships an MCP server in a
`mcp/` subdirectory (TypeScript + Bun) that wraps a local SQLite database. We
want the same *shape* of deliverable here, but the data layer is different:
instead of querying a database, the engleader MCP server shells out to
`eng <command> --json` and passes the envelope through. This keeps the bash
scripts as the single source of truth — no metric logic is reimplemented, so
the server can never drift from the CLI.

## Solution

Two deliverables:

1. **An MCP server** (`mcp/index.ts`, TypeScript + Bun) that exposes the
   JSON-emitting `eng` commands as MCP tools. Each tool spawns
   `eng <command> --json`, captures stdout, and returns the envelope (or
   surfaces the `{error, code}` object on failure).

2. **An `eng mcp` subcommand** bundled into the existing `eng` bash CLI that
   detects which agents are installed, asks the user which to wire up, and
   executes the registration for them (default-safe, with `--dry-run` and
   backups).

This mirrors engsight's `mcp/` layout while leaning on engleader's existing
`--json` contract as the data source. **From-source only** — no npm publishing
in v1. The `eng mcp install` subcommand replaces the "copy this path yourself"
install step that engsight documents.

## Part 1 — MCP Server (`mcp/`)

### Layout

A new `mcp/` subdirectory inside `engleader-tools-scripts/`, mirroring
engsight:

```
mcp/
  index.ts          # single-file server: helpers + tool registrations
  package.json      # private:true, @modelcontextprotocol/sdk, zod, @types/bun
  tsconfig.json
  README.md
  .gitignore        # node_modules, bun.lock as appropriate
```

Run via `bun run index.ts`. No `bin` entry and no shebang (from-source only).

### `resolveEngBin()`

Resolves the `eng` binary in this order:

1. `ENG_BIN` environment variable (explicit override)
2. `eng` on `PATH`

If neither is found, throw a clear, actionable error naming the right package
manager per platform:

> `eng` not found. Install it with `brew install eng-leader-tools` (macOS/Linux)
> or `scoop install eng-leader-tools` (Windows), or set the `ENG_BIN`
> environment variable to its path.

This mirrors engsight's "database not found, run install.sh" pattern.

### `runEng(command, positional, opts)`

The one piece of real logic in the server.

- Builds argv: `eng <command> <...positional> --json`.
- If `opts.team` is set, passes `ENG_TEAM=<team>` in the child environment
  (the `eng` wrapper reads `ENG_TEAM` and resolves it to team members).
- Spawns the subprocess and captures stdout + exit code.
- **Exit 0** → parse stdout as JSON, return it as MCP text content
  (`JSON.stringify(envelope, null, 2)`).
- **Non-zero exit** → parse stdout as the `{error, code}` object and surface it
  as an MCP error so the agent sees what failed (codes: `AUTH`,
  `RATE_LIMIT`, `NOT_FOUND`, `DEP_MISSING`, `BAD_ARGS`, `UNKNOWN`).
- **Unparseable stdout** (either case) → wrapped error that includes the raw
  stdout/stderr for debugging.

### Tools (13, one per metric)

Each tool maps 1:1 to an `eng` command that emits the JSON envelope, plus
`pull-discussion` (structured text). Tool names use the `eng_` prefix and
underscores.

| Tool | `eng` command | Positional params | Team-aware |
|------|---------------|-------------------|------------|
| `eng_lead_time` | `lead-time` | `repo`, `window_days?` (default 30) | yes |
| `eng_change_failure_rate` | `change-failure-rate` | `repo`, `window_days?` (default 30) | no |
| `eng_deploy_frequency` | `deploy-frequency` | `repo`, `window_days?` (default 90) | no |
| `eng_review_time` | `review-time` | `repo`, `count?` | yes |
| `eng_pr_size` | `pr-size` | `repo`, `count?` | yes |
| `eng_files_per_pr` | `files-per-pr` | `repo`, `count?` | yes |
| `eng_stale_prs` | `stale-prs` | `repo`, `limit?` | yes |
| `eng_review_load` | `review-load` | `repo`, `count?` | yes |
| `eng_code_churn` | `code-churn` | `repo`, `window_days?` (default 30), `min_changes?` | no |
| `eng_contributor_patterns` | `contributor-patterns` | `repo`, `count?` | yes |
| `eng_lottery_factor` | `lottery-factor` | `repo`, `count?` | no |
| `eng_dependency_changes` | `dependency-changes` | `repo`, `window_days?` | no |
| `eng_pull_discussion` | `pull-discussion` | `repo`, `pr_number` | no |

Parameter conventions (zod-typed):

- `repo` — string, **required**, `owner/repo`. Auto-detection isn't useful in
  an MCP server (no fixed cwd), so `repo` is always explicit.
- The second positional (`window_days` / `count` / `limit`) — number,
  optional; each tool's description states the script's documented default.
- `team` — string, optional; included **only** on the 7 team-aware v1 tools.
  Maps to `ENG_TEAM` in the child env. The README lists 9 team-supported
  commands, but 2 (`quick-reviews`, `files-per-pr-live`) are out of scope for
  v1, leaving 7 team-aware tools: `lead-time`, `review-time`, `pr-size`,
  `files-per-pr`, `stale-prs`, `review-load`, `contributor-patterns`.
- `eng_code_churn` also accepts an optional `min_changes` (third positional).
- `eng_pull_discussion` requires `pr_number` (number) and returns the raw
  structured discussion text for the agent to read directly.

`eng_pull_discussion` returns text rather than the JSON envelope (the
`pull-discussion` command outputs structured text by design). `runEng` returns
its stdout verbatim as text content with no JSON parsing for this tool.

## Part 2 — `eng mcp` Subcommand

A new subcommand in the `eng` bash CLI that installs the MCP server into the
user's agents. The `eng` script already resolves its own real location into
`SCRIPT_DIR` (with symlink following), so it can locate `mcp/index.ts` as
`$SCRIPT_DIR/mcp/index.ts`.

### `eng mcp install` (interactive, default-safe)

1. **Check for `bun`** (required to run the server). If absent, warn and link
   to https://bun.sh, then continue (so the user still sees what would be
   installed).
2. **Resolve server path** — `$SCRIPT_DIR/mcp/index.ts`.
3. **Detect installed agents**:
   - **Claude Code** — `claude` on `PATH` → CLI registration
   - **Cursor** — `~/.cursor/mcp.json` → JSON merge
   - **VS Code (Copilot)** — user `mcp.json` / settings → JSON merge
   - **Gemini CLI** — its config file → JSON merge
   - **Codex** — its config file → merge
   - **Windsurf** — its config file → JSON merge
   - **OpenCode** — `~/.config/opencode/opencode.json` (`mcp` block, local
     server with a `command` array) → JSON merge
4. **Prompt** the user: install into `[a]ll` / `[c]hoose` / `[q]uit`. Show
   exactly what will be written for each selected agent before proceeding.
5. **Execute** on confirmation:
   - Claude Code → run
     `claude mcp add engleader -s user -- bun run $SCRIPT_DIR/mcp/index.ts`
   - JSON-config agents → **back up the file first** (e.g.
     `mcp.json.bak-<timestamp>`), then merge the `engleader` entry
     idempotently (skip or update if an `engleader` entry already exists).
6. **Verify and report** success per agent.

Each agent's registration points at `bun run $SCRIPT_DIR/mcp/index.ts`. The
JSON entry shape per agent follows that agent's own schema (command + args
array), e.g.:

```json
{
  "command": "bun",
  "args": ["run", "/abs/path/to/engleader-tools-scripts/mcp/index.ts"]
}
```

### Flags

- `--dry-run` — print what would be written for each detected agent; write
  nothing.
- `--agent <name>` — non-interactive, install into one named agent.
- `--all` — non-interactive, install into all detected agents.
- `-h` / `--help` — usage.

### `eng mcp` with no subcommand

Print short help describing `install`, the flags, and the prerequisite that the
`eng` binary and `bun` must be present.

## Error Handling

- **Server, binary missing** — actionable per-package-manager message (see
  `resolveEngBin()`).
- **Server, command failure** — the `{error, code}` envelope is surfaced to the
  agent verbatim; the contract's codes carry the meaning.
- **Server, malformed output** — wrapped error including raw stdout/stderr.
- **Installer, missing `bun`** — warn and link to bun.sh; still show planned
  registrations.
- **Installer, unknown/unwritable agent config** — skip that agent with a
  printed note; do not abort the whole run.
- **Installer, JSON merges** — always back up the target file before writing;
  merges are idempotent (re-running does not duplicate the `engleader` entry).

## Testing

### Server

- `bun test` with the `eng` subprocess **mocked** to return canned envelopes
  and `{error, code}` objects. Assert that:
  - each tool builds the correct argv (command + positional order),
  - `team` is passed as `ENG_TEAM` in the child env (and is only present on the
    7 team-aware tools),
  - successful envelopes are returned as text content,
  - non-zero exits surface as MCP errors carrying the contract code,
  - `eng_pull_discussion` returns raw text without JSON parsing.
- One **integration smoke test** that runs a real `eng <cmd> --json` if `eng`
  and an authenticated `gh` are present; **skipped** otherwise.

### Installer

- Shell tests (bats-style or plain shell) for:
  - agent **detection** logic (presence/absence of each CLI/config),
  - **JSON merge** against temporary config files — assert the `engleader`
    entry is added, that re-running is **idempotent**, and that a **backup**
    file is created,
  - `--dry-run` writes **nothing**,
  - `--agent` / `--all` run non-interactively.

## Out of Scope (v1, YAGNI)

- `lead-time-user`, `files-per-pr-live`, `quick-reviews`, `contributions` — do
  not emit the JSON envelope yet (they accept/reject `--json` but don't call
  `emit_json`). Add as tools once they gain envelope support.
- `analyze-discussion` — redundant in an MCP context (the agent *is* the LLM);
  `eng_pull_discussion` gives the agent the raw discussion to analyze directly.
- **npm publishing** / `bunx` distribution — from-source only for v1.
- **Caching / SQLite layer** in front of the GitHub API — revisit only if rate
  limits become a problem in practice.
- **`eng mcp uninstall`** — possible follow-up; not in v1.
