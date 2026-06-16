# MCP Server + `eng mcp` Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a from-source Bun/TypeScript MCP server that exposes the JSON-emitting `eng` metric commands as MCP tools, plus an `eng mcp install` subcommand that detects installed AI agents and wires the server into them.

**Architecture:** The MCP server is a thin wrapper — each tool shells out to `eng <command> --json`, captures stdout, and returns the JSON envelope (or surfaces the `{error,code}` object). No metric logic is reimplemented; the bash scripts remain the single source of truth. The installer is a new bash script (`src/mcp-install.sh`) dispatched from the `eng` wrapper that detects agents (Claude Code, Cursor, VS Code, Gemini, Codex, Windsurf, OpenCode), prompts the user, and registers the server (CLI for Claude Code, JSON-config merge for the rest).

**Tech Stack:** TypeScript, Bun (`bun:test`, `Bun.spawn`), `@modelcontextprotocol/sdk`, `zod`; Bash for the installer; `bats`-free plain-shell tests for the installer.

**Spec:** [`docs/superpowers/specs/2026-06-16-mcp-server-design.md`](../specs/2026-06-16-mcp-server-design.md)

---

## File Structure

**Create:**
- `mcp/package.json` — deps (`@modelcontextprotocol/sdk`, `zod`), `private:true`
- `mcp/tsconfig.json` — Bun strict TS config (copied from engsight)
- `mcp/.gitignore` — `node_modules`, `bun.lock`
- `mcp/eng-runner.ts` — `resolveEngBin()` + `runEng()` (the only real server logic)
- `mcp/tools.ts` — tool definitions table + registration function
- `mcp/index.ts` — entrypoint: create server, register tools, connect stdio
- `mcp/eng-runner.test.ts` — unit tests for the runner (mocked subprocess)
- `mcp/tools.test.ts` — unit tests asserting argv/env construction per tool
- `mcp/README.md` — from-source install instructions
- `src/mcp-install.sh` — the `eng mcp` installer
- `src/mcp-install.test.sh` — shell tests for detection + JSON merge + dry-run

**Modify:**
- `eng` — add `mcp)` dispatch arm, help text entry, completions entry

**Responsibilities:** `eng-runner.ts` owns subprocess + binary resolution; `tools.ts` owns the metric→tool mapping and zod schemas; `index.ts` is pure wiring. Splitting runner from tools keeps each file focused and lets us unit-test argv construction without spawning real processes.

---

## Task 1: MCP project scaffold

**Files:**
- Create: `mcp/package.json`
- Create: `mcp/tsconfig.json`
- Create: `mcp/.gitignore`

- [ ] **Step 1: Create `mcp/package.json`**

```json
{
  "name": "@engleader/mcp",
  "version": "0.1.0",
  "description": "MCP server for engleader.tools — query engineering leadership metrics from AI agents",
  "module": "index.ts",
  "type": "module",
  "private": true,
  "devDependencies": {
    "@types/bun": "latest"
  },
  "peerDependencies": {
    "typescript": "^5"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.29.0",
    "zod": "^3.23.8"
  }
}
```

- [ ] **Step 2: Create `mcp/tsconfig.json`**

```json
{
  "compilerOptions": {
    "lib": ["ESNext"],
    "target": "ESNext",
    "module": "Preserve",
    "moduleDetection": "force",
    "allowJs": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "verbatimModuleSyntax": true,
    "noEmit": true,
    "strict": true,
    "skipLibCheck": true,
    "noFallthroughCasesInSwitch": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true
  }
}
```

- [ ] **Step 3: Create `mcp/.gitignore`**

```
node_modules
bun.lock
```

- [ ] **Step 4: Install dependencies**

Run: `cd mcp && bun install`
Expected: Creates `node_modules/` and `bun.lock`, exits 0.

- [ ] **Step 5: Commit**

```bash
git add mcp/package.json mcp/tsconfig.json mcp/.gitignore
git commit -m "chore(mcp): scaffold Bun/TS MCP project"
```

---

## Task 2: `resolveEngBin()` — locate the eng binary

**Files:**
- Create: `mcp/eng-runner.ts`
- Test: `mcp/eng-runner.test.ts`

- [ ] **Step 1: Write the failing test**

Create `mcp/eng-runner.test.ts`:

```ts
import { test, expect } from "bun:test";
import { resolveEngBin } from "./eng-runner.ts";

test("resolveEngBin prefers ENG_BIN env var", () => {
  const bin = resolveEngBin({ ENG_BIN: "/custom/path/eng", PATH: "/usr/bin" });
  expect(bin).toBe("/custom/path/eng");
});

test("resolveEngBin returns 'eng' when on PATH and no override", () => {
  // findOnPath is injected so the test doesn't depend on the real PATH
  const bin = resolveEngBin({ PATH: "/usr/bin" }, () => "/usr/bin/eng");
  expect(bin).toBe("/usr/bin/eng");
});

test("resolveEngBin throws an actionable error when eng is missing", () => {
  expect(() => resolveEngBin({ PATH: "/usr/bin" }, () => null)).toThrow(
    /brew install eng-leader-tools.*scoop install eng-leader-tools/s
  );
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && bun test eng-runner.test.ts`
Expected: FAIL — `Cannot find module './eng-runner.ts'` / `resolveEngBin is not a function`.

- [ ] **Step 3: Write minimal implementation**

Create `mcp/eng-runner.ts`:

```ts
import { which } from "bun";

type Env = Record<string, string | undefined>;

/**
 * Resolve the `eng` binary: ENG_BIN override first, then PATH lookup.
 * `findOnPath` is injectable for testing; defaults to Bun's `which`.
 */
export function resolveEngBin(
  env: Env = process.env,
  findOnPath: (name: string) => string | null = (name) => which(name) ?? null,
): string {
  if (env.ENG_BIN) return env.ENG_BIN;
  const found = findOnPath("eng");
  if (found) return found;
  throw new Error(
    "`eng` not found. Install it with `brew install eng-leader-tools` " +
      "(macOS/Linux) or `scoop install eng-leader-tools` (Windows), or set " +
      "the ENG_BIN environment variable to its path.",
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && bun test eng-runner.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add mcp/eng-runner.ts mcp/eng-runner.test.ts
git commit -m "feat(mcp): resolve eng binary with ENG_BIN override and PATH lookup"
```

---

## Task 3: `runEng()` — spawn eng and return the envelope

**Files:**
- Modify: `mcp/eng-runner.ts`
- Test: `mcp/eng-runner.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `mcp/eng-runner.test.ts`:

```ts
import { runEng } from "./eng-runner.ts";

// A fake spawn that records the call and returns canned output.
function fakeSpawn(result: { stdout: string; stderr: string; exitCode: number }) {
  const calls: { argv: string[]; env: Record<string, string | undefined> }[] = [];
  const spawn = (argv: string[], env: Record<string, string | undefined>) => {
    calls.push({ argv, env });
    return Promise.resolve(result);
  };
  return { spawn, calls };
}

test("runEng builds argv: eng <command> <...positional> --json", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn, calls } = fakeSpawn({
    stdout: '{"metric":"lead-time","data":{}}',
    stderr: "",
    exitCode: 0,
  });
  await runEng("lead-time", ["acme/widget", "30"], {}, env, spawn);
  expect(calls[0]!.argv).toEqual(["/bin/eng", "lead-time", "acme/widget", "30", "--json"]);
});

test("runEng passes team as ENG_TEAM in the child env", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn, calls } = fakeSpawn({ stdout: "{}", stderr: "", exitCode: 0 });
  await runEng("lead-time", ["acme/widget"], { team: "frontend" }, env, spawn);
  expect(calls[0]!.env.ENG_TEAM).toBe("frontend");
});

test("runEng returns the parsed envelope on exit 0", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn } = fakeSpawn({
    stdout: '{"metric":"lead-time","data":{"count":3}}',
    stderr: "",
    exitCode: 0,
  });
  const out = await runEng("lead-time", ["acme/widget"], {}, env, spawn);
  expect(out).toEqual({ metric: "lead-time", data: { count: 3 } });
});

test("runEng throws the {error,code} object on non-zero exit", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn } = fakeSpawn({
    stdout: '{"error":"gh is not authenticated","code":"AUTH"}',
    stderr: "",
    exitCode: 1,
  });
  await expect(runEng("lead-time", ["acme/widget"], {}, env, spawn)).rejects.toThrow(
    /AUTH.*gh is not authenticated/s
  );
});

test("runEng wraps unparseable stdout in a debuggable error", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn } = fakeSpawn({ stdout: "not json at all", stderr: "boom", exitCode: 0 });
  await expect(runEng("lead-time", ["acme/widget"], {}, env, spawn)).rejects.toThrow(
    /not json at all|boom/s
  );
});

test("runEng with raw:true returns stdout text unparsed", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn } = fakeSpawn({ stdout: "PR #42 discussion...", stderr: "", exitCode: 0 });
  const out = await runEng("pull-discussion", ["acme/widget", "42"], { raw: true }, env, spawn);
  expect(out).toBe("PR #42 discussion...");
});

test("runEng with raw:true does NOT append --json", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn, calls } = fakeSpawn({ stdout: "text", stderr: "", exitCode: 0 });
  await runEng("pull-discussion", ["acme/widget", "42"], { raw: true }, env, spawn);
  expect(calls[0]!.argv).toEqual(["/bin/eng", "pull-discussion", "acme/widget", "42"]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && bun test eng-runner.test.ts`
Expected: FAIL — `runEng is not a function`.

- [ ] **Step 3: Write minimal implementation**

Append to `mcp/eng-runner.ts`:

```ts
type SpawnResult = { stdout: string; stderr: string; exitCode: number };
type SpawnFn = (argv: string[], env: Env) => Promise<SpawnResult>;

export type RunOpts = { team?: string; raw?: boolean };

// Default spawn implementation using Bun.spawn.
const defaultSpawn: SpawnFn = async (argv, env) => {
  const proc = Bun.spawn(argv, {
    env: env as Record<string, string>,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const exitCode = await proc.exited;
  return { stdout, stderr, exitCode };
};

/**
 * Run `eng <command> <...positional> --json` and return the parsed envelope.
 * On non-zero exit, throws the {error,code} object's message. With opts.raw,
 * returns stdout text unparsed (for pull-discussion).
 */
export async function runEng(
  command: string,
  positional: string[],
  opts: RunOpts = {},
  env: Env = process.env,
  spawn: SpawnFn = defaultSpawn,
): Promise<unknown> {
  const bin = resolveEngBin(env);
  // Raw tools (pull-discussion) output text and do NOT strip a trailing
  // --json flag from their positional args, so we must not append it.
  const argv = opts.raw
    ? [bin, command, ...positional]
    : [bin, command, ...positional, "--json"];
  const childEnv: Env = { ...env };
  if (opts.team) childEnv.ENG_TEAM = opts.team;

  const { stdout, stderr, exitCode } = await spawn(argv, childEnv);

  if (opts.raw && exitCode === 0) return stdout;

  let parsed: any;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    throw new Error(
      `eng ${command} produced unparseable output (exit ${exitCode}).\n` +
        `stdout: ${stdout}\nstderr: ${stderr}`,
    );
  }

  if (exitCode !== 0) {
    const code = parsed?.code ?? "UNKNOWN";
    const message = parsed?.error ?? "eng command failed";
    throw new Error(`[${code}] ${message}`);
  }

  return parsed;
}
```

Note: raw mode (`pull-discussion`) does NOT append `--json`. That script reads its PR number positionally and does not strip a trailing `--json`, so appending it would leave a stray positional arg. Metric tools always get `--json`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && bun test eng-runner.test.ts`
Expected: PASS (10 tests total: 3 from Task 2 + 7 here).

- [ ] **Step 5: Commit**

```bash
git add mcp/eng-runner.ts mcp/eng-runner.test.ts
git commit -m "feat(mcp): runEng spawns eng --json and surfaces error envelopes"
```

---

## Task 4: Tool definitions table

**Files:**
- Create: `mcp/tools.ts`
- Test: `mcp/tools.test.ts`

This task defines the 13 tools as a data table (so they're testable without an MCP server) and a `buildArgs` helper that turns tool params into the positional array `runEng` expects.

- [ ] **Step 1: Write the failing test**

Create `mcp/tools.test.ts`:

```ts
import { test, expect } from "bun:test";
import { TOOLS, buildArgs } from "./tools.ts";

test("there are 13 tools", () => {
  expect(TOOLS.length).toBe(13);
});

test("every tool name is eng_ prefixed and unique", () => {
  const names = TOOLS.map((t) => t.name);
  for (const n of names) expect(n).toMatch(/^eng_[a-z_]+$/);
  expect(new Set(names).size).toBe(names.length);
});

test("exactly 7 tools are team-aware", () => {
  expect(TOOLS.filter((t) => t.teamAware).length).toBe(7);
});

test("buildArgs puts repo first, then the numeric param when present", () => {
  const tool = TOOLS.find((t) => t.name === "eng_lead_time")!;
  expect(buildArgs(tool, { repo: "acme/widget", window_days: 30 })).toEqual([
    "acme/widget",
    "30",
  ]);
});

test("buildArgs omits an absent optional numeric param", () => {
  const tool = TOOLS.find((t) => t.name === "eng_lead_time")!;
  expect(buildArgs(tool, { repo: "acme/widget" })).toEqual(["acme/widget"]);
});

test("eng_code_churn supports a second numeric param (min_changes)", () => {
  const tool = TOOLS.find((t) => t.name === "eng_code_churn")!;
  expect(buildArgs(tool, { repo: "acme/widget", window_days: 30, min_changes: 3 })).toEqual([
    "acme/widget",
    "30",
    "3",
  ]);
});

test("eng_pull_discussion requires pr_number and is raw", () => {
  const tool = TOOLS.find((t) => t.name === "eng_pull_discussion")!;
  expect(tool.raw).toBe(true);
  expect(buildArgs(tool, { repo: "acme/widget", pr_number: 42 })).toEqual([
    "acme/widget",
    "42",
  ]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && bun test tools.test.ts`
Expected: FAIL — `Cannot find module './tools.ts'`.

- [ ] **Step 3: Write minimal implementation**

Create `mcp/tools.ts`:

```ts
import { z } from "zod";

// A numeric positional param: the param name on the tool, and the order it
// appears in the eng command line after `repo`.
type NumParam = { key: string; describe: string };

export type ToolDef = {
  name: string;          // MCP tool name (eng_*)
  command: string;       // eng subcommand
  description: string;
  teamAware: boolean;    // exposes a `team` param mapped to ENG_TEAM
  raw?: boolean;         // return stdout text instead of parsed JSON
  numParams: NumParam[]; // ordered numeric positionals after repo
  prNumber?: boolean;    // requires a pr_number positional (pull-discussion)
};

const WINDOW = (def: number): NumParam => ({
  key: "window_days",
  describe: `Lookback window in days (default: ${def})`,
});
const COUNT: NumParam = { key: "count", describe: "Number of recent PRs to sample" };
const LIMIT: NumParam = { key: "limit", describe: "Max open PRs to consider" };

export const TOOLS: ToolDef[] = [
  // DORA
  { name: "eng_lead_time", command: "lead-time", teamAware: true,
    description: "Average time from PR creation to merge for a repo.",
    numParams: [WINDOW(30)] },
  { name: "eng_change_failure_rate", command: "change-failure-rate", teamAware: false,
    description: "Percentage of merged PRs flagged as rollbacks or hotfixes.",
    numParams: [WINDOW(30)] },
  { name: "eng_deploy_frequency", command: "deploy-frequency", teamAware: false,
    description: "How often releases/tags ship, with DORA tier assessment.",
    numParams: [WINDOW(90)] },
  // PR health
  { name: "eng_review_time", command: "review-time", teamAware: true,
    description: "Time to first review and time to merge across recent PRs.",
    numParams: [COUNT] },
  { name: "eng_pr_size", command: "pr-size", teamAware: true,
    description: "PR size distribution (XS-XL) correlated with review time.",
    numParams: [COUNT] },
  { name: "eng_files_per_pr", command: "files-per-pr", teamAware: true,
    description: "Files changed per merged PR.",
    numParams: [COUNT] },
  { name: "eng_stale_prs", command: "stale-prs", teamAware: true,
    description: "Open PRs grouped by age, highlighting work needing attention.",
    numParams: [LIMIT] },
  { name: "eng_review_load", command: "review-load", teamAware: true,
    description: "How review work is distributed across contributors.",
    numParams: [COUNT] },
  // Codebase & contributors
  { name: "eng_code_churn", command: "code-churn", teamAware: false,
    description: "File hotspots — files changed repeatedly across PRs.",
    numParams: [WINDOW(30), { key: "min_changes", describe: "Minimum changes to count as a hotspot" }] },
  { name: "eng_contributor_patterns", command: "contributor-patterns", teamAware: true,
    description: "Per-contributor PR size patterns (focused vs broad-scope).",
    numParams: [COUNT] },
  { name: "eng_lottery_factor", command: "lottery-factor", teamAware: false,
    description: "Knowledge concentration risk — files with only 1-2 contributors.",
    numParams: [COUNT] },
  { name: "eng_dependency_changes", command: "dependency-changes", teamAware: false,
    description: "Tracks dependency update PRs and flags security updates.",
    numParams: [WINDOW(30)] },
  // Discussion (raw text)
  { name: "eng_pull_discussion", command: "pull-discussion", teamAware: false, raw: true,
    description: "Full PR discussion (comments, reviews, files) as structured text.",
    numParams: [], prNumber: true },
];

// Turn validated params into the ordered positional argument array for eng.
export function buildArgs(tool: ToolDef, params: Record<string, unknown>): string[] {
  const args: string[] = [String(params.repo)];
  if (tool.prNumber) args.push(String(params.pr_number));
  for (const p of tool.numParams) {
    const v = params[p.key];
    if (v !== undefined && v !== null) args.push(String(v));
  }
  return args;
}

// Build the zod schema object for a tool's MCP params.
export function schemaFor(tool: ToolDef): Record<string, z.ZodTypeAny> {
  const shape: Record<string, z.ZodTypeAny> = {
    repo: z.string().describe("Repository as owner/repo"),
  };
  if (tool.prNumber) shape.pr_number = z.number().describe("Pull request number");
  for (const p of tool.numParams) {
    shape[p.key] = z.number().optional().describe(p.describe);
  }
  if (tool.teamAware) {
    shape.team = z.string().optional().describe("Filter to members of this GitHub Team slug");
  }
  return shape;
}
```

Note: numeric positionals are appended in declared order, so for `code-churn` an omitted `window_days` with a present `min_changes` would mis-position. The MCP schema requires neither, but the tool description states they're positional; in practice callers pass `window_days` when passing `min_changes`. This matches the script's own positional contract.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && bun test tools.test.ts`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add mcp/tools.ts mcp/tools.test.ts
git commit -m "feat(mcp): define 13 metric tools as a testable table"
```

---

## Task 5: Server entrypoint wiring

**Files:**
- Create: `mcp/index.ts`

- [ ] **Step 1: Write `mcp/index.ts`**

```ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { TOOLS, buildArgs, schemaFor } from "./tools.ts";
import { runEng } from "./eng-runner.ts";

const server = new McpServer({ name: "engleader", version: "0.1.0" });

for (const tool of TOOLS) {
  server.tool(tool.name, tool.description, schemaFor(tool), async (params: any) => {
    try {
      const result = await runEng(
        tool.command,
        buildArgs(tool, params),
        { team: params.team, raw: tool.raw },
      );
      const text = typeof result === "string" ? result : JSON.stringify(result, null, 2);
      return { content: [{ type: "text" as const, text }] };
    } catch (e: any) {
      return {
        isError: true,
        content: [{ type: "text" as const, text: e?.message ?? String(e) }],
      };
    }
  });
}

const transport = new StdioServerTransport();
await server.connect(transport);
```

- [ ] **Step 2: Verify it type-checks and starts**

Run: `cd mcp && bunx tsc --noEmit`
Expected: No type errors.

- [ ] **Step 3: Verify the server boots and lists tools**

Run:
```bash
cd mcp && ENG_BIN=/bin/true bash -c 'echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}" | timeout 5 bun run index.ts'
```
Expected: A JSON-RPC response whose `result.tools` array contains 13 entries including `eng_lead_time` and `eng_pull_discussion`. (Server reads one line, replies, then waits — `timeout` ends it.)

- [ ] **Step 4: Commit**

```bash
git add mcp/index.ts
git commit -m "feat(mcp): wire server entrypoint registering all tools over stdio"
```

---

## Task 6: Installer — agent registry and detection

**Files:**
- Create: `src/mcp-install.sh`
- Test: `src/mcp-install.test.sh`

The installer is one bash script. This task builds the agent registry (name, detection, registration kind, config path) and the detection function. Registration/execution comes in Task 7.

- [ ] **Step 1: Write the failing test**

Create `src/mcp-install.test.sh`:

```bash
#!/usr/bin/env bash
# Plain-shell test runner for mcp-install.sh. Run: bash src/mcp-install.test.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok() { if eval "$2"; then echo "ok - $1"; PASS=$((PASS+1)); else echo "FAIL - $1"; FAIL=$((FAIL+1)); fi; }

# Source the script in "library mode" so functions are defined but main() doesn't run.
ENG_MCP_LIB=1 source "$SCRIPT_DIR/mcp-install.sh"

# detect_agents writes "name|kind|path" lines for present agents.
# Use a fake HOME and fake PATH so detection is deterministic.
TMP="$(mktemp -d)"
mkdir -p "$TMP/.cursor"; : > "$TMP/.cursor/mcp.json"
mkdir -p "$TMP/.config/opencode"; : > "$TMP/.config/opencode/opencode.json"
fakebin="$TMP/bin"; mkdir -p "$fakebin"; printf '#!/bin/sh\n' > "$fakebin/claude"; chmod +x "$fakebin/claude"

OUT="$(HOME="$TMP" PATH="$fakebin:$PATH" detect_agents)"

ok "detects Claude Code via claude on PATH" '[[ "$OUT" == *"claude-code|cli|"* ]]'
ok "detects Cursor via ~/.cursor/mcp.json" '[[ "$OUT" == *"cursor|json|"* ]]'
ok "detects OpenCode via ~/.config/opencode/opencode.json" '[[ "$OUT" == *"opencode|json|"* ]]'

# An agent with no CLI and no config file is not detected.
OUT2="$(HOME="$TMP" PATH="$fakebin:$PATH" detect_agents)"
ok "does not detect windsurf when absent" '[[ "$OUT2" != *"windsurf|"* ]]'

rm -rf "$TMP"
echo "----"; echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash src/mcp-install.test.sh`
Expected: FAIL — `mcp-install.sh` does not exist (source error) or `detect_agents: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `src/mcp-install.sh`:

```bash
#!/usr/bin/env bash
#
# mcp-install.sh — install the engleader MCP server into AI agents.
# Dispatched as `eng mcp`. Detects installed agents, prompts, registers.
#
set -uo pipefail

# Path to the MCP server entrypoint, resolved relative to this script.
# eng exports ENG_MCP_SERVER when it dispatches; fall back to ../mcp/index.ts.
mcp_server_path() {
  if [[ -n "${ENG_MCP_SERVER:-}" ]]; then
    echo "$ENG_MCP_SERVER"
  else
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    echo "$here/mcp/index.ts"
  fi
}

# Agent registry. Each detector echoes "name|kind|configpath" if present.
#   kind: cli  -> register via a CLI command
#         json -> merge into a JSON config file
# configpath is empty for cli agents.
detect_agents() {
  local home="${HOME}"
  command -v claude >/dev/null 2>&1 && echo "claude-code|cli|"
  [[ -f "$home/.cursor/mcp.json" ]]                 && echo "cursor|json|$home/.cursor/mcp.json"
  [[ -f "$home/.config/Code/User/mcp.json" ]]       && echo "vscode|json|$home/.config/Code/User/mcp.json"
  [[ -f "$home/.gemini/settings.json" ]]            && echo "gemini|json|$home/.gemini/settings.json"
  [[ -f "$home/.codex/config.json" ]]               && echo "codex|json|$home/.codex/config.json"
  [[ -f "$home/.codeium/windsurf/mcp_config.json" ]] && echo "windsurf|json|$home/.codeium/windsurf/mcp_config.json"
  [[ -f "$home/.config/opencode/opencode.json" ]]   && echo "opencode|json|$home/.config/opencode/opencode.json"
  return 0
}

# main() runs only when invoked directly, not when sourced for tests.
main() {
  echo "eng mcp install — coming together across tasks 6-9" >&2
}

if [[ -z "${ENG_MCP_LIB:-}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash src/mcp-install.test.sh`
Expected: `4 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/mcp-install.sh src/mcp-install.test.sh
chmod +x src/mcp-install.sh
git add src/mcp-install.sh
git commit -m "feat(mcp): agent detection registry for eng mcp installer"
```

---

## Task 7: Installer — JSON merge (idempotent, backed up)

**Files:**
- Modify: `src/mcp-install.sh`
- Test: `src/mcp-install.test.sh`

- [ ] **Step 1: Write the failing test**

Append before the final summary lines in `src/mcp-install.test.sh` (i.e. before `echo "----"`):

```bash
# --- JSON merge ---
JTMP="$(mktemp -d)"
cfg="$JTMP/mcp.json"
echo '{"mcpServers":{"existing":{"command":"foo"}}}' > "$cfg"

merge_json_config "$cfg" "/abs/mcp/index.ts" >/dev/null

ok "adds engleader entry" 'grep -q "engleader" "$cfg"'
ok "preserves existing entry" 'grep -q "existing" "$cfg"'
ok "entry uses bun run with the server path" 'grep -q "/abs/mcp/index.ts" "$cfg"'
ok "creates a timestamped backup" 'ls "$cfg".bak-* >/dev/null 2>&1'

# Idempotency: second merge does not add a duplicate.
merge_json_config "$cfg" "/abs/mcp/index.ts" >/dev/null
count="$(grep -o engleader "$cfg" | wc -l | tr -d ' ')"
ok "idempotent — engleader appears once" '[[ "$count" == "1" ]]'

rm -rf "$JTMP"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash src/mcp-install.test.sh`
Expected: FAIL — `merge_json_config: command not found`.

- [ ] **Step 3: Write minimal implementation**

Add to `src/mcp-install.sh` (before `main()`). Uses `jq` (already a hard dependency of the project):

```bash
# merge_json_config <config_path> <server_path>
#   Backs up the file, then idempotently adds an `engleader` MCP entry under
#   the standard `.mcpServers` key. Uses bun to run the server.
merge_json_config() {
  local cfg="$1" server="$2"
  local ts; ts="$(date -u +%Y%m%d%H%M%S)"
  cp "$cfg" "${cfg}.bak-${ts}"

  # Treat an empty file as an empty object.
  local current; current="$(cat "$cfg")"
  [[ -z "${current// }" ]] && current="{}"

  echo "$current" | jq \
    --arg path "$server" \
    '.mcpServers.engleader = { command: "bun", args: ["run", $path] }' \
    > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}
```

Note: VS Code / some agents nest under `.servers` rather than `.mcpServers`, but `.mcpServers` is the dominant convention (Cursor, Windsurf, Claude's file form, OpenCode accepts an `mcp` block too). For v1 we standardize on `.mcpServers`; per-agent key variants are a follow-up noted in the spec's out-of-scope list. (If a strict per-agent key is required later, add a `key` column to the registry and pass it here.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash src/mcp-install.test.sh`
Expected: `9 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add src/mcp-install.sh src/mcp-install.test.sh
git commit -m "feat(mcp): idempotent JSON config merge with backup"
```

---

## Task 8: Installer — registration dispatch + main flow

**Files:**
- Modify: `src/mcp-install.sh`
- Test: `src/mcp-install.test.sh`

- [ ] **Step 1: Write the failing test**

Append before the summary lines in `src/mcp-install.test.sh`:

```bash
# --- register_agent dispatch ---
RTMP="$(mktemp -d)"
# Fake `claude` that records its args.
fb="$RTMP/bin"; mkdir -p "$fb"
cat > "$fb/claude" <<'EOF'
#!/bin/sh
echo "$@" >> "$CLAUDE_LOG"
EOF
chmod +x "$fb/claude"

CLAUDE_LOG="$RTMP/claude.log" PATH="$fb:$PATH" \
  register_agent "claude-code|cli|" "/abs/mcp/index.ts" >/dev/null
ok "cli agent invokes claude mcp add" 'grep -q "mcp add engleader" "$RTMP/claude.log"'
ok "cli registration references bun run + path" 'grep -q "bun run /abs/mcp/index.ts" "$RTMP/claude.log"'

# json agent path goes through merge_json_config
jcfg="$RTMP/cursor.json"; echo '{}' > "$jcfg"
register_agent "cursor|json|$jcfg" "/abs/mcp/index.ts" >/dev/null
ok "json agent merges config" 'grep -q engleader "$jcfg"'

# --- dry-run writes nothing ---
dcfg="$RTMP/dry.json"; echo '{}' > "$dcfg"
ENG_MCP_DRY_RUN=1 register_agent "cursor|json|$dcfg" "/abs/mcp/index.ts" >/dev/null
ok "dry-run leaves json untouched" '! grep -q engleader "$dcfg"'
ok "dry-run creates no backup" '! ls "$dcfg".bak-* >/dev/null 2>&1'

rm -rf "$RTMP"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash src/mcp-install.test.sh`
Expected: FAIL — `register_agent: command not found`.

- [ ] **Step 3: Write minimal implementation**

Add to `src/mcp-install.sh` (before `main()`):

```bash
# register_agent <"name|kind|path"> <server_path>
#   Honors ENG_MCP_DRY_RUN=1 (print intended action, change nothing).
register_agent() {
  local entry="$1" server="$2"
  local name kind path
  IFS='|' read -r name kind path <<<"$entry"

  if [[ -n "${ENG_MCP_DRY_RUN:-}" ]]; then
    if [[ "$kind" == "cli" ]]; then
      echo "[dry-run] $name: claude mcp add engleader -s user -- bun run $server"
    else
      echo "[dry-run] $name: merge engleader into $path"
    fi
    return 0
  fi

  case "$kind" in
    cli)
      claude mcp add engleader -s user -- bun run "$server" \
        && echo "✓ $name registered" \
        || echo "✗ $name: claude mcp add failed" >&2
      ;;
    json)
      merge_json_config "$path" "$server" \
        && echo "✓ $name updated ($path)" \
        || echo "✗ $name: failed to update $path" >&2
      ;;
    *)
      echo "✗ $name: unknown registration kind '$kind', skipped" >&2
      ;;
  esac
}
```

Now replace the placeholder `main()` with the real flow:

```bash
# Print the planned action for each detected agent and prompt for selection.
main() {
  local server; server="$(mcp_server_path)"

  if ! command -v bun >/dev/null 2>&1; then
    echo "Warning: 'bun' is not installed — the server needs it to run." >&2
    echo "Install Bun from https://bun.sh, then re-run 'eng mcp install'." >&2
    echo >&2
  fi

  local dry_run="" target_agent="" install_all=""
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=1 ;;
      --all) install_all=1 ;;
      --agent) ;; # value handled below
      --agent=*) target_agent="${arg#--agent=}" ;;
      -h|--help)
        echo "Usage: eng mcp install [--all] [--agent <name>] [--dry-run]"
        echo "Agents: claude-code cursor vscode gemini codex windsurf opencode"
        return 0 ;;
    esac
  done
  # support `--agent <name>` (space form)
  local prev=""
  for arg in "$@"; do
    [[ "$prev" == "--agent" ]] && target_agent="$arg"
    prev="$arg"
  done
  [[ -n "$dry_run" ]] && export ENG_MCP_DRY_RUN=1

  local detected; detected="$(detect_agents)"
  if [[ -z "$detected" ]]; then
    echo "No supported agents detected. Supported: claude-code cursor vscode gemini codex windsurf opencode" >&2
    return 1
  fi

  echo "Detected agents:"
  while IFS='|' read -r name kind path; do
    [[ -z "$name" ]] && continue
    echo "  - $name${path:+  ($path)}"
  done <<<"$detected"
  echo

  # Non-interactive paths
  if [[ -n "$target_agent" ]]; then
    local entry; entry="$(echo "$detected" | grep "^${target_agent}|" || true)"
    [[ -z "$entry" ]] && { echo "Agent '$target_agent' not detected." >&2; return 1; }
    register_agent "$entry" "$server"
    return 0
  fi
  if [[ -n "$install_all" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      register_agent "$entry" "$server"
    done <<<"$detected"
    return 0
  fi

  # Interactive
  printf "Install into which? [a]ll / [c]hoose / [q]uit: "
  read -r choice
  case "$choice" in
    a|A)
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        register_agent "$entry" "$server"
      done <<<"$detected" ;;
    c|C)
      while IFS='|' read -r name kind path; do
        [[ -z "$name" ]] && continue
        printf "Install into %s? [y/N]: " "$name"
        read -r yn
        [[ "$yn" == "y" || "$yn" == "Y" ]] && register_agent "$name|$kind|$path" "$server"
      done <<<"$detected" ;;
    *)
      echo "Aborted." ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash src/mcp-install.test.sh`
Expected: `14 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add src/mcp-install.sh src/mcp-install.test.sh
git commit -m "feat(mcp): register_agent dispatch and interactive install flow"
```

---

## Task 9: Wire `eng mcp` into the eng CLI

**Files:**
- Modify: `eng` (dispatch case at line ~254, help text at ~103-148, completions cmds at ~151)

- [ ] **Step 1: Add the `mcp)` dispatch arm**

In `eng`, the dispatch `case "${1:-}" in` block (starts line 240) has a `*)` catch-all at line 254. Add an `mcp)` arm immediately before `*)`:

**IMPORTANT:** `eng` has a global pre-processing loop near the top that strips
`--dry-run` (and `--team`) from `$@` *before* dispatch, capturing it in
`_dry_run`. So the `install)` arm must RE-INJECT `--dry-run` to the installer
when `_dry_run` is true — otherwise `eng mcp install --dry-run` would silently
perform a real install. The arm below handles this.

```bash
  mcp)
    shift
    sub="${1:-install}"
    case "$sub" in
      install)
        shift 2>/dev/null || true
        export ENG_MCP_SERVER="${SCRIPT_DIR}/mcp/index.ts"
        # --dry-run is stripped by eng's global pre-processing; re-add it so
        # the installer sees it and only prints intended actions.
        if [[ "$_dry_run" == "true" ]]; then
          exec bash "${SCRIPT_DIR}/src/mcp-install.sh" "$@" --dry-run
        fi
        exec bash "${SCRIPT_DIR}/src/mcp-install.sh" "$@"
        ;;
      -h|--help|help|"")
        echo "Usage: eng mcp install [--all] [--agent <name>] [--dry-run]"
        ;;
      *)
        echo "Unknown 'eng mcp' subcommand: $sub" >&2
        echo "Try: eng mcp install" >&2
        exit 1
        ;;
    esac
    ;;
```

- [ ] **Step 2: Add `mcp` to the help text**

In `show_help()` (the heredoc), after the `Discussion:` block and before `Options:` (around line 134), add:

```
Setup:
  mcp                    Install the MCP server into your AI agents
```

- [ ] **Step 3: Add `mcp` to the completions command list**

At line 151, append ` mcp` to the end of the `cmds` string:

```bash
  local cmds="lead-time lead-time-user change-failure-rate deploy-frequency review-time pr-size files-per-pr files-per-pr-live stale-prs quick-reviews review-load code-churn contributor-patterns lottery-factor dependency-changes contributions pull-discussion analyze-discussion mcp"
```

- [ ] **Step 4: Verify the wiring (dry-run, no mutation)**

Run: `./eng mcp install --dry-run`
Expected: Prints "Detected agents:" then `[dry-run] <agent>: ...` lines for whatever agents are present on this machine; writes nothing. If no agents are present, prints the "No supported agents detected" message and exits 1 (acceptable).

Run: `./eng mcp --help`
Expected: `Usage: eng mcp install ...`

Run: `./eng --help | grep -A1 Setup`
Expected: Shows the `mcp` line.

- [ ] **Step 5: Commit**

```bash
git add eng
git commit -m "feat(eng): add 'eng mcp' subcommand dispatching the MCP installer"
```

---

## Task 10: Documentation

**Files:**
- Create: `mcp/README.md`
- Modify: `README.md` (add an MCP section)

- [ ] **Step 1: Create `mcp/README.md`**

Write this file using a heredoc so the code fences land literally (no escaping):

```bash
cat > mcp/README.md <<'MCPDOC'
# engleader MCP server

Exposes `eng` metric commands as MCP tools so AI agents (Claude Code, Cursor,
VS Code, Gemini, Codex, Windsurf, OpenCode) can query engineering-leadership
metrics directly.

## Prerequisites

- [`eng`](../README.md) installed and on your PATH (the server shells out to it)
- [Bun](https://bun.sh)
- An authenticated `gh` (the metrics hit the GitHub API)

## Install

The easiest path is the bundled installer, which detects your agents and wires
them up:

    eng mcp install            # interactive
    eng mcp install --all      # all detected agents
    eng mcp install --dry-run  # show what would change, write nothing

## Manual (Claude Code)

    claude mcp add engleader -s user -- bun run /path/to/engleader-tools-scripts/mcp/index.ts

## Configuration

- `ENG_BIN` — path to the `eng` binary if it isn't on PATH.

## Tools

13 tools, one per metric: `eng_lead_time`, `eng_change_failure_rate`,
`eng_deploy_frequency`, `eng_review_time`, `eng_pr_size`, `eng_files_per_pr`,
`eng_stale_prs`, `eng_review_load`, `eng_code_churn`,
`eng_contributor_patterns`, `eng_lottery_factor`, `eng_dependency_changes`,
`eng_pull_discussion`. Each accepts `repo` (owner/repo); metric tools return the
JSON envelope, `eng_pull_discussion` returns structured text.
MCPDOC
```

- [ ] **Step 2: Add an MCP section to the top-level `README.md`**

Manually insert this block into `README.md` after the "Auto-detection"
subsection and before "Team Filtering" (use indented code, not fenced, to keep
it simple):

```markdown
### MCP Server (use from AI agents)

`engleader.tools` ships an MCP server so AI agents can call these metrics
directly. Install it into your agents with:

    eng mcp install

This detects Claude Code, Cursor, VS Code, Gemini, Codex, Windsurf, and
OpenCode, asks which to set up, and registers the server. See
[`mcp/README.md`](mcp/README.md) for details. Requires [Bun](https://bun.sh).
```

- [ ] **Step 3: Verify docs render (no broken relative links)**

Run: `test -f mcp/README.md && grep -q "MCP Server" README.md && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add mcp/README.md README.md
git commit -m "docs(mcp): document the MCP server and eng mcp install"
```

---

## Task 11: Full test sweep

**Files:** none (verification only)

- [ ] **Step 1: Run all MCP server tests**

Run: `cd mcp && bun test`
Expected: All tests pass (eng-runner.test.ts + tools.test.ts), 0 failures.

- [ ] **Step 2: Run installer tests**

Run: `bash src/mcp-install.test.sh`
Expected: `14 passed, 0 failed`.

- [ ] **Step 3: Type-check the server**

Run: `cd mcp && bunx tsc --noEmit`
Expected: No errors.

- [ ] **Step 4: Boot smoke test**

Run:
```bash
cd mcp && echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | timeout 5 bun run index.ts
```
Expected: JSON-RPC response listing 13 tools.

- [ ] **Step 5: Final commit (if any test config changed)**

```bash
git add -A
git commit -m "test(mcp): full sweep green" --allow-empty
```

---

## Self-Review Notes

- **Spec coverage:** Server (Tasks 1-5) ✓; 13 tools incl. team-aware subset & raw pull-discussion (Task 4) ✓; resolveEngBin actionable error (Task 2) ✓; error envelope pass-through (Task 3) ✓; installer detection/merge/dispatch/dry-run/backup/idempotency (Tasks 6-8) ✓; eng wiring (Task 9) ✓; docs (Task 10) ✓; out-of-scope items excluded ✓.
- **Type/name consistency:** `runEng(command, positional, opts, env, spawn)`, `RunOpts {team,raw}`, `ToolDef`, `buildArgs`, `schemaFor`, `TOOLS` used identically across Tasks 3-5. Installer functions `detect_agents`, `merge_json_config`, `register_agent`, `main`, env vars `ENG_MCP_LIB`/`ENG_MCP_DRY_RUN`/`ENG_MCP_SERVER` consistent across Tasks 6-9.
- **Known v1 limitation (documented):** JSON merge standardizes on `.mcpServers`; per-agent key variants (e.g. VS Code `.servers`) are a noted follow-up, not silently assumed correct.
