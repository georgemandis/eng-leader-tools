# Ship the MCP server as a compiled binary

## Problem

The `eng mcp` MCP server was built as from-source TypeScript, run via
`bun run mcp/index.ts` pointing at the repo. This works in a `git clone` but
**breaks when packaged** for distribution:

- The Homebrew formula's `install` copies only `eng` + `src/` — it never installs
  `mcp/`. So `/opt/homebrew/Cellar/eng-leader-tools/<v>/libexec/mcp/index.ts`
  does not exist, and `eng mcp install` registers a path that isn't there.
- Even if `mcp/` were copied, `node_modules` is (correctly) gitignored, so the
  server's `@modelcontextprotocol/sdk` / `zod` imports would fail — and there is
  no guaranteed `bun` at runtime, nor network during an offline Homebrew build.

Verified root cause: a source-tarball install cannot run raw `.ts` with external
deps. Verified fix: `bun build index.ts --compile` produces a self-contained
binary (213 modules bundled; runs with no `bun` on PATH and no `node_modules`)
that boots over stdio and serves all 13 tools.

## Solution

Distribute the MCP server as a **compiled, per-platform standalone binary**
(`eng-mcp`), attached as release assets, following the established pattern from
`little-money-ideas/.github/workflows/holdline-cli-release.yml` (matrix
`bun build --compile --target` → release assets → tap/bucket download).

End state: `brew install` / `scoop install` produces a working `eng` CLI **and** a
working `eng-mcp` binary in one step; `eng mcp install` registers that binary
directly (no `bun`, no `index.ts`).

## Scope (three repos)

- **`eng-leader-tools`** (source): new release workflow, `eng mcp build`
  subcommand, `mcp/package.json` build script, binary resolution + new
  registration shape in `eng` and `src/mcp-install.sh`, updated installer tests.
- **`homebrew-tap`**: formula gains per-platform `resource` blocks for the
  `eng-mcp` asset + staging into libexec.
- **`scoop-bucket`**: manifest gains the `eng-mcp.exe` windows asset.

## Components

### 1. Release workflow — `.github/workflows/mcp-release.yml` (new)

Mirrors holdline-cli-release.yml.

- **Trigger:** `push: tags: ["v*"]`.
- **Permissions:** `contents: write` (to attach assets to the release).
- **Matrix** (os, bun target, asset label):
  - `macos-latest`, `bun-darwin-arm64`, `macos-aarch64`
  - `macos-13`, `bun-darwin-x64`, `macos-x86_64` (Intel Mac; `macos-13` is the
    last Intel runner)
  - `ubuntu-latest`, `bun-linux-x64`, `linux-x86_64`
  - `windows-latest`, `bun-windows-x64`, `windows-x86_64`
- **Steps per platform:**
  1. `actions/checkout@v4`
  2. `oven-sh/setup-bun@v2`
  3. `bun install` (working-directory `mcp/`)
  4. Compile: `bun build index.ts --compile --target=<target>
     --outfile eng-mcp[.exe]` (working-directory `mcp/`)
  5. Smoke-run: pipe a `tools/list` JSON-RPC line into the binary with
     `ENG_BIN=/bin/true` (or `cmd /c` on Windows) and assert the output contains
     `eng_lead_time`. (On Windows use `where.exe`-friendly equivalent; a
     `--version`-style check isn't available since the server has no flags — the
     tools/list smoke test is the check.)
  6. Package: `eng-mcp-v<version>-<asset>.tar.gz` (Unix, contains `eng-mcp`) /
     `eng-mcp-v<version>-<asset>.zip` (Windows, contains `eng-mcp.exe`).
     `<version>` = `${GITHUB_REF_NAME#v}`.
  7. `softprops/action-gh-release@v2` with the default `GITHUB_TOKEN`,
     `tag_name: ${{ github.ref_name }}`, `files:` the packaged archives.
     (Attaches to eng-leader-tools' own release — no cross-repo PAT.)

### 2. `eng mcp build` + `mcp/package.json` build script

- **`mcp/package.json`** gains:
  `"scripts": { "build": "bun install && bun build index.ts --compile --outfile eng-mcp" }`
  (local-platform build; CI overrides `--target` directly rather than via this
  script).
- **`eng mcp build`** (new sub-arm in the `eng` `mcp)` dispatch): runs
  `bun build "${SCRIPT_DIR}/mcp/index.ts" --compile --outfile "${SCRIPT_DIR}/eng-mcp"`
  after a `bun install` in `mcp/`. Requires `bun`; if `bun` is absent, error with
  a link to https://bun.sh. Prints the resulting binary path on success.
- This is the single canonical compile command devs use after a `git clone`, and
  it's what the missing-binary error points to.

### 3. Binary resolution + registration shape

- **Resolution** (`eng` exports for the installer; installer also resolves):
  `eng-mcp` lives at `${SCRIPT_DIR}/eng-mcp` (libexec, beside `eng` + `src/`).
  Honor an `ENG_MCP_BIN` override. The `eng mcp` dispatch arm exports
  `ENG_MCP_BIN="${SCRIPT_DIR}/eng-mcp"` (replacing the old
  `ENG_MCP_SERVER=.../mcp/index.ts`).
- **`mcp-install.sh` changes:**
  - Add `mcp_bin_path()` (mirrors the old `mcp_server_path()`): `ENG_MCP_BIN`
    override → else `<dir>/eng-mcp` resolved relative to the script's `..`.
  - `register_agent` registers the binary directly:
    - cli: `claude mcp add engleader -s user -- "<bin>"`
    - json: `{ "command": "<bin>", "args": [] }` (was
      `{ command: "bun", args: ["run", <path>] }`)
    - dry-run lines updated to show `<bin>` instead of `bun run <path>`.
  - **Missing-binary guard:** before registering (non-dry-run), if the resolved
    `eng-mcp` binary does not exist, print
    `✗ eng-mcp not found at <path>. Run 'eng mcp build' (requires bun), or reinstall via brew/scoop.`
    to stderr and `return 1`. No `bun run` fallback.
- **`merge_json_config`** writes `{ command: "<bin>", args: [] }` under
  `.mcpServers.engleader` (the URL-hash and surgical-delete logic is unchanged;
  only the entry shape changes).

### 4. Homebrew formula (`homebrew-tap/Formula/eng-leader-tools.rb`)

- Main `url` stays the source tarball (the CLI).
- Add per-platform `resource "mcp"` inside `on_macos`/`on_arm`/`on_intel` and
  `on_linux`, each pointing at the matching `eng-mcp-v<version>-<asset>.tar.gz`
  asset with its own `sha256`.
- `def install`: keep `libexec.install "src"` + `libexec.install "eng"`; add
  `resource("mcp").stage { libexec.install "eng-mcp" }` so the binary lands at
  `libexec/eng-mcp` (where `eng` resolves it). Do NOT symlink `eng-mcp` into
  `bin` (it's invoked by agents via the registered absolute path, not by users).
- `update.sh` already hashes whatever URL each `url`/`resource` points at, so the
  new resource hashes are filled correctly on the next run (no manual hashing).

### 5. Scoop manifest (`scoop-bucket/eng-leader-tools.json`)

- The CLI still installs from the source tarball. Add the compiled
  `eng-mcp.exe` (windows-x86_64 asset) using Scoop's **multi-URL** form: `url`
  and `hash` become arrays `[ <source-tarball>, <eng-mcp zip> ]`, with a matching
  `extract_dir` array `[ "eng-leader-tools-<version>", "" ]` (the zip extracts
  `eng-mcp.exe` to the package root). `bin` stays `"eng"` only — `eng-mcp.exe` is
  invoked by agents via its absolute path in the package dir, not exposed as a
  shim.
- **Requirement (the acceptance criterion):** after `scoop install`,
  `eng-mcp.exe` exists in the package dir alongside the extracted CLI source.
  The plan's first Scoop step VERIFIES this multi-URL+extract_dir array behaves
  as described (Scoop applies each `extract_dir` entry to the correspondingly
  indexed `url`); if Scoop's semantics differ, fall back to a second standalone
  manifest entry. This verification happens before wiring, so the shape is
  confirmed, not assumed.

## Data flow

tag push → workflow compiles 4 binaries → attaches to the GitHub release →
formula/manifest download the matching `eng-mcp` into the install dir →
`eng mcp install` registers `<dir>/eng-mcp` into agents → the agent launches the
standalone binary (no bun, no node_modules).

## Error handling

- Missing `eng-mcp` at registration → actionable `eng mcp build` / reinstall
  message, `return 1`, no fallback.
- `eng mcp build` with no `bun` → error linking to bun.sh.
- Formula/manifest hashing → handled automatically by the existing robust
  `update.sh` (hashes the exact asset URL).

## Testing

- **Existing suites stay green:** `mcp/*.test.ts` (20) unaffected;
  `mcp-install.test.sh` (48) — UPDATE the registration-shape assertions: tests
  that asserted `bun run` / `[dry-run] ...: ... bun run ...` now assert the
  `eng-mcp` binary command. The choose/agent-detection/uninstall logic is
  unchanged.
- **New install-test:** the missing-binary guard — `register_agent` with a
  non-existent `ENG_MCP_BIN` prints the `eng-mcp not found` error and returns
  non-zero (dry-run still prints without the guard, since dry-run mutates
  nothing).
- **New compile smoke test:** `eng mcp build` (or `bun run build` in `mcp/`)
  produces an `eng-mcp` binary that, piped a `tools/list` request, lists 13
  tools. Gated on `bun` being available (skip with a note otherwise).
- **CI smoke-run** per platform inside the workflow (step 5 above).

## Release process (new order — important)

Because a release now depends on compiled assets:

1. Bump `VERSION`, commit, tag `vX.Y.Z`, push tag.
2. The `mcp-release.yml` workflow runs on the tag, compiles the 4 binaries, and
   attaches them to the release. **Wait for it to finish.**
3. Create/verify the GitHub release (the workflow attaches assets to the tag's
   release; `gh release create` may run before or after — assets can attach to an
   existing release).
4. Only AFTER assets exist: run `update.sh` in homebrew-tap and scoop-bucket
   (now resolves both the source-tarball hash and the per-platform `eng-mcp`
   asset hashes), commit, push.

This ordering will be documented in the plan and is the guard against a repeat of
the "manifest points at an asset that isn't built yet" failure mode.

## Out of Scope (YAGNI)

- `linux-arm64` build (add to the matrix later if a user needs it).
- Code-signing / notarizing the macOS binary (real concern for Gatekeeper on
  downloaded binaries, but separate; note and revisit — a Homebrew-installed
  binary is generally exempt from the quarantine prompt, so not blocking).
- Publishing the server to npm / `bunx` distribution.
- Symlinking `eng-mcp` into `bin` (it's invoked by absolute path, not by users).
