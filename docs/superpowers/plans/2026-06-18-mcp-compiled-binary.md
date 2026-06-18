# Ship the MCP server as a compiled binary — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Distribute the `eng mcp` server as a compiled, per-platform standalone `eng-mcp` binary (no bun/node_modules at runtime), so it survives Homebrew/Scoop packaging; `eng mcp install` registers that binary directly.

**Architecture:** A GitHub Actions release workflow matrix-compiles `eng-mcp` via `bun build --compile --target` and attaches the 4 binaries to the eng-leader-tools release. The installer (`src/mcp-install.sh`) resolves `${SCRIPT_DIR}/eng-mcp` (with `ENG_MCP_BIN` override) and registers `{command:"<bin>", args:[]}` — no bun. The Homebrew formula stages the matching binary into libexec via per-platform `resource` blocks; the Scoop manifest adds it via multi-URL.

**Tech Stack:** Bash, Bun (`bun build --compile`), jq, GitHub Actions, Homebrew Ruby formula, Scoop JSON manifest.

**Spec:** [`docs/superpowers/specs/2026-06-18-mcp-compiled-binary-design.md`](../specs/2026-06-18-mcp-compiled-binary-design.md)

**THREE REPOS:**
- `~/Projects/engleader.tools/engleader-tools-scripts` (source) — Tasks 1–6. On branch `mcp-compiled-binary` (already created; spec committed there).
- `~/Projects/recurse/2026/homebrew-tap` — Task 7.
- `~/Projects/recurse/2026/scoop-bucket` — Task 8.

`src/mcp-install.sh` uses `set -uo pipefail` (NOT -e) and BSD `sed -i ''`. Tests source it with `ENG_MCP_LIB=1`; the summary block (`echo "----" ...`) stays last in the test file.

---

## File Structure

**Source repo (`engleader-tools-scripts`):**
- `src/mcp-install.sh` — rename `mcp_server_path`→`mcp_bin_path` (resolve `eng-mcp`, `ENG_MCP_BIN` override); `register_agent` registers the binary directly + missing-binary guard; `merge_json_config` writes `{command:<bin>,args:[]}`. (Tasks 1–3)
- `src/mcp-install.test.sh` — update registration-shape assertions; add missing-binary-guard test. (Tasks 1–3, alongside)
- `mcp/package.json` — add `"build"` script. (Task 4)
- `eng` — `mcp build` sub-arm; swap `ENG_MCP_SERVER`→`ENG_MCP_BIN` in the install/uninstall arms; help text. (Tasks 4–5)
- `.github/workflows/mcp-release.yml` — new matrix compile→assets workflow. (Task 6)

**homebrew-tap:** `Formula/eng-leader-tools.rb` — per-platform `resource` + stage. (Task 7)
**scoop-bucket:** `eng-leader-tools.json` — multi-URL for `eng-mcp.exe`. (Task 8)

---

## Task 1: Installer — resolve the binary (`mcp_bin_path`)

**Files:**
- Modify: `src/mcp-install.sh` (rename/rework `mcp_server_path`)
- Test: `src/mcp-install.test.sh`

**Context:** The current `mcp_server_path()` resolves `ENG_MCP_SERVER` → else `<dir>/mcp/index.ts`. It becomes `mcp_bin_path()` resolving `ENG_MCP_BIN` → else `<dir>/eng-mcp`. The `<dir>` is the script's parent (libexec layout: `eng`, `src/mcp-install.sh`, `eng-mcp` all in libexec; the script is at `src/mcp-install.sh` so `..` = libexec).

- [ ] **Step 1: Append a failing test** to `src/mcp-install.test.sh` BEFORE the final `echo "----"` block:

```bash
# --- mcp_bin_path resolution ---
ok "mcp_bin_path honors ENG_MCP_BIN override" '[[ "$(ENG_MCP_BIN=/custom/eng-mcp mcp_bin_path)" == "/custom/eng-mcp" ]]'
ok "mcp_bin_path falls back to <dir>/eng-mcp" '[[ "$(env -u ENG_MCP_BIN mcp_bin_path)" == */eng-mcp ]]'
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash src/mcp-install.test.sh 2>&1 | grep -E 'mcp_bin_path|passed,'`
Expected: FAIL — `mcp_bin_path: command not found`.

- [ ] **Step 3: Replace `mcp_server_path` with `mcp_bin_path`** in `src/mcp-install.sh`:

```bash
# mcp_bin_path
#   Resolve the compiled eng-mcp binary: ENG_MCP_BIN override, else the
#   eng-mcp sitting beside this script's parent dir (libexec).
mcp_bin_path() {
  if [[ -n "${ENG_MCP_BIN:-}" ]]; then
    echo "$ENG_MCP_BIN"
  else
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
    echo "$here/eng-mcp"
  fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash src/mcp-install.test.sh 2>&1 | grep -E 'mcp_bin_path|passed,'`
Expected: both `mcp_bin_path` tests pass. (Other tests will still pass for now — they reference `register_agent`/`main` which still use the old `$server` value via the renamed function; `main` calls `mcp_server_path` though, so this step BREAKS `main`'s callers — see note.)

NOTE: `main()` and `uninstall_main()` call `mcp_server_path` (line ~94). Renaming creates an undefined-function call. Fix those call sites in THIS step too: change `server="$(mcp_server_path)"` to `bin="$(mcp_bin_path)"` in BOTH `main` and `uninstall_main`, and rename the local var `server`→`bin` plus its uses (`register_agent "$entry" "$server"` → `"$bin"`, etc.). Do a full search: `grep -n 'mcp_server_path\|"\$server"\|server=' src/mcp-install.sh` and update every hit. After this step there must be ZERO references to `mcp_server_path` or a `server` local in main/uninstall_main.

- [ ] **Step 5: Verify whole suite still parses + the rename is complete**

Run: `bash -n src/mcp-install.sh && grep -c 'mcp_server_path' src/mcp-install.sh`
Expected: syntax OK; `0` occurrences of `mcp_server_path`.

(The `register_agent`/`merge_json_config` signatures still take a 2nd arg named `server` internally — that's fixed in Tasks 2–3. Some `bun run` assertions will still pass here because those functions are unchanged yet. That's expected mid-refactor; Task 2 changes them.)

- [ ] **Step 6: Commit**

```bash
git add src/mcp-install.sh src/mcp-install.test.sh
git commit -m "refactor(mcp): mcp_bin_path resolves eng-mcp binary (ENG_MCP_BIN)"
```

---

## Task 2: Installer — register the binary (no bun)

**Files:**
- Modify: `src/mcp-install.sh` (`register_agent` + missing-binary guard)
- Test: `src/mcp-install.test.sh` (update bun-run assertions; add guard test)

**Context:** `register_agent` currently registers `bun run <server>` (cli) / `merge_json_config` (json) and prints `bun run` dry-run lines. It must register the binary directly and guard against a missing binary.

- [ ] **Step 1: Update the existing tests** in `src/mcp-install.test.sh` that assert `bun run`, to assert the binary shape. Make these exact edits:

Replace line ~62:
```bash
ok "cli registration references bun run + path" 'grep -q "bun run /abs/mcp/index.ts" "$RTMP/claude.log"'
```
with:
```bash
ok "cli registration references the eng-mcp binary" 'grep -q "mcp add engleader" "$RTMP/claude.log" && grep -q "/abs/eng-mcp" "$RTMP/claude.log"'
```

In the same block (~line 60), the `register_agent "claude-code|cli|" "/abs/mcp/index.ts"` calls now pass a binary path — change the 2nd arg from `/abs/mcp/index.ts` to `/abs/eng-mcp` in ALL register_agent test calls (lines ~60, 66, 71, 95) and the merge_json_config calls (lines ~35, 43). Also update the merge assertion at line ~39:
```bash
ok "entry uses bun run with the server path" 'grep -q "/abs/mcp/index.ts" "$cfg"'
```
to:
```bash
ok "json entry references the eng-mcp binary" 'grep -q "/abs/eng-mcp" "$cfg"'
```

- [ ] **Step 2: Add a NEW failing test** for the missing-binary guard, before the `echo "----"` block:

```bash
# --- register_agent guards against a missing eng-mcp binary (non-dry-run) ---
GTMP="$(mktemp -d)"
gfb="$GTMP/bin"; mkdir -p "$gfb"
cat > "$gfb/claude" <<'EOF'
#!/bin/sh
echo "$@" >> "$CLAUDE_LOG"
EOF
chmod +x "$gfb/claude"
# binary does NOT exist at this path:
OUT_MISSING="$(CLAUDE_LOG="$GTMP/c.log" PATH="$gfb:$PATH" register_agent "claude-code|cli|" "$GTMP/nope-eng-mcp" 2>&1)"; rc=$?
ok "missing binary -> error" '[[ "$rc" -ne 0 && "$OUT_MISSING" == *"eng-mcp not found"* ]]'
ok "missing binary -> did NOT call claude" '[[ ! -f "$GTMP/c.log" ]]'
# dry-run with missing binary still just prints (no guard, no mutation)
OUT_DRYMISS="$(ENG_MCP_DRY_RUN=1 PATH="$gfb:$PATH" register_agent "claude-code|cli|" "$GTMP/nope-eng-mcp" 2>&1)"
ok "dry-run prints even if binary absent" '[[ "$OUT_DRYMISS" == *"[dry-run] claude-code"* ]]'
rm -rf "$GTMP"
```

- [ ] **Step 3: Run to verify failures**

Run: `bash src/mcp-install.test.sh 2>&1 | grep -E 'eng-mcp|missing binary|passed,'`
Expected: the updated bun-run assertions FAIL (still emitting `bun run`), and the new guard tests FAIL (`register_agent` doesn't guard yet).

- [ ] **Step 4: Rework `register_agent`** in `src/mcp-install.sh`. Replace the whole function with:

```bash
# register_agent <"name|kind|path"> <eng-mcp-binary>
#   Registers the engleader MCP server (a compiled binary) into an agent.
#   Honors ENG_MCP_DRY_RUN=1. Errors (return 1) if the binary is missing.
register_agent() {
  local entry="$1" bin="$2"
  local name kind path
  IFS='|' read -r name kind path <<<"$entry"

  if [[ -n "${ENG_MCP_DRY_RUN:-}" ]]; then
    if [[ "$kind" == "cli" ]]; then
      echo "[dry-run] $name: claude mcp add engleader -s user -- $bin"
    else
      echo "[dry-run] $name: merge engleader into $path"
    fi
    return 0
  fi

  if [[ ! -x "$bin" && ! -f "$bin" ]]; then
    echo "✗ eng-mcp not found at $bin. Run 'eng mcp build' (requires bun), or reinstall via brew/scoop." >&2
    return 1
  fi

  case "$kind" in
    cli)
      claude mcp add engleader -s user -- "$bin" \
        && echo "✓ $name registered" \
        || echo "✗ $name: claude mcp add failed" >&2
      ;;
    json)
      merge_json_config "$path" "$bin" \
        && echo "✓ $name updated ($path)" \
        || echo "✗ $name: failed to update $path" >&2
      ;;
    *)
      echo "✗ $name: unknown registration kind '$kind', skipped" >&2
      ;;
  esac
}
```

(The guard uses `! -x "$bin" && ! -f "$bin"` so a present-but-not-yet-executable file in tests still passes; in practice the installed binary is executable. The test uses a path that doesn't exist at all, so the guard fires.)

- [ ] **Step 5: Run to verify passes**

Run: `bash src/mcp-install.test.sh 2>&1 | grep -E 'passed,'`
Expected: all pass (the merge json test still passes because `merge_json_config` still works — Task 3 changes its output shape, and that test asserts `/abs/eng-mcp` is present, which it will be once Task 3 lands; if it fails HERE on the json-entry assertion, that's expected until Task 3 — note it and proceed). To avoid a red mid-state, run only the cli + guard tests now: `bash src/mcp-install.test.sh 2>&1 | grep -E 'cli registration|missing binary|dry-run prints'` and confirm those pass.

- [ ] **Step 6: Commit**

```bash
git add src/mcp-install.sh src/mcp-install.test.sh
git commit -m "feat(mcp): register the eng-mcp binary directly with missing-binary guard"
```

---

## Task 3: Installer — JSON entry shape (`{command:<bin>, args:[]}`)

**Files:**
- Modify: `src/mcp-install.sh` (`merge_json_config`)
- Test: `src/mcp-install.test.sh` (assert new entry shape)

- [ ] **Step 1: Update/confirm the merge test.** The json-entry assertion (updated in Task 2 to `grep -q "/abs/eng-mcp" "$cfg"`) plus the existing idempotency/backup tests should remain. Add one asserting the exact shape, before the `echo "----"` block:

```bash
# --- merge_json_config writes {command:<bin>, args:[]} ---
JS2="$(mktemp -d)"; jc="$JS2/m.json"; echo '{}' > "$jc"
merge_json_config "$jc" "/abs/eng-mcp" >/dev/null
ok "json entry command is the binary" '[[ "$(jq -r ".mcpServers.engleader.command" "$jc")" == "/abs/eng-mcp" ]]'
ok "json entry args is empty array" '[[ "$(jq -c ".mcpServers.engleader.args" "$jc")" == "[]" ]]'
rm -rf "$JS2"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash src/mcp-install.test.sh 2>&1 | grep -E 'json entry|passed,'`
Expected: FAIL — current merge writes `{command:"bun", args:["run", <path>]}`, so `.command` is `bun`, not the binary.

- [ ] **Step 3: Update `merge_json_config`** — change only the jq expression. Replace:

```bash
  echo "$current" | jq \
    --arg path "$server" \
    '.mcpServers.engleader = { command: "bun", args: ["run", $path] }' \
    > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
```
with:
```bash
  echo "$current" | jq \
    --arg bin "$2" \
    '.mcpServers.engleader = { command: $bin, args: [] }' \
    > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
```

Also rename the function's 2nd positional for clarity: change the header line `local cfg="$1" server="$2"` to `local cfg="$1" bin="$2"` (and the jq `--arg bin "$2"` can then be `--arg bin "$bin"`). Keep the backup + atomic write unchanged.

- [ ] **Step 4: Run the FULL suite**

Run: `bash src/mcp-install.test.sh 2>&1 | tail -1`
Expected: all pass (count will be the prior total + the new tests from Tasks 1–3).

- [ ] **Step 5: Commit**

```bash
git add src/mcp-install.sh src/mcp-install.test.sh
git commit -m "feat(mcp): JSON registration uses {command:<eng-mcp>, args:[]}"
```

---

## Task 4: `eng mcp build` + package.json build script

**Files:**
- Modify: `mcp/package.json` (add build script)
- Modify: `eng` (add `build)` sub-arm to the `mcp)` dispatch)

- [ ] **Step 1: Add the build script to `mcp/package.json`.** Read it first; it currently has no `scripts` block. Add one (keep all existing fields):

```json
  "scripts": {
    "build": "bun install && bun build index.ts --compile --outfile eng-mcp"
  },
```

(Place it after the `"private": true,` line or wherever valid; ensure the JSON stays valid.)

- [ ] **Step 2: Verify the build script works locally**

Run: `cd mcp && bun run build && ls -lh eng-mcp && rm -f eng-mcp`
Expected: produces an `eng-mcp` binary (tens of MB), exits 0. Then removed (don't commit the binary — see Step 4).

- [ ] **Step 3: Ensure the compiled binary is gitignored.** The compile in Step 2 wrote `mcp/eng-mcp`. Add it to `mcp/.gitignore` (which currently has `node_modules` and `bun.lock`):

Append a line so `mcp/.gitignore` contains:
```
node_modules
bun.lock
eng-mcp
```

- [ ] **Step 4: Add the `build)` sub-arm** to the `eng` `mcp)` dispatch, immediately after the `uninstall)` arm's `;;` and before `-h|--help|help|""`:

```bash
      build)
        if ! command -v bun >/dev/null 2>&1; then
          echo "Error: 'bun' is required to build the MCP server. Install it from https://bun.sh" >&2
          exit 1
        fi
        echo "Building eng-mcp from ${SCRIPT_DIR}/mcp ..."
        ( cd "${SCRIPT_DIR}/mcp" && bun install && bun build index.ts --compile --outfile "${SCRIPT_DIR}/eng-mcp" ) || {
          echo "Error: eng-mcp build failed" >&2
          exit 1
        }
        echo "✓ Built ${SCRIPT_DIR}/eng-mcp"
        ;;
```

- [ ] **Step 5: Update the `eng mcp` help line** to mention build. Replace:
```bash
        echo "Usage: eng mcp <install|uninstall> [--all] [--agent <name>] [--dry-run]"
```
with:
```bash
        echo "Usage: eng mcp <install|uninstall|build> [--all] [--agent <name>] [--dry-run]"
```

- [ ] **Step 6: Verify**

Run: `bash -n eng && ./eng mcp --help`
Expected: syntax OK; help shows `<install|uninstall|build>`.

Run: `./eng mcp build && ls -lh eng-mcp`
Expected: builds `eng-mcp` at the repo root (which IS `${SCRIPT_DIR}` for a dev checkout); binary present. Confirm it's gitignored: `git check-ignore eng-mcp` → prints `eng-mcp`. Then `rm -f eng-mcp`.

NOTE: in a dev checkout `${SCRIPT_DIR}` is the repo root, so `eng mcp build` writes `./eng-mcp` and `mcp_bin_path` (Task 1) resolves `<src/..>` = repo root → `./eng-mcp`. Consistent. Add the root `eng-mcp` to the repo root `.gitignore` too (create/append): ensure repo-root `.gitignore` contains a line `eng-mcp`. Check whether a root `.gitignore` exists first; if it does, append; if not, create it with `eng-mcp`.

- [ ] **Step 7: Commit**

```bash
git add mcp/package.json mcp/.gitignore eng .gitignore
git commit -m "feat(eng): add 'eng mcp build' to compile the eng-mcp binary"
```

---

## Task 5: Swap `ENG_MCP_SERVER` → `ENG_MCP_BIN` in eng dispatch + installer tests

**Files:**
- Modify: `eng` (install/uninstall arms export ENG_MCP_BIN)
- Modify: `src/mcp-install.test.sh` (env var rename in main-driving tests)

- [ ] **Step 1: Update the `eng` install + uninstall arms.** In BOTH the `install)` and `uninstall)` sub-arms, replace:
```bash
        export ENG_MCP_SERVER="${SCRIPT_DIR}/mcp/index.ts"
```
with:
```bash
        export ENG_MCP_BIN="${SCRIPT_DIR}/eng-mcp"
```
(Two occurrences — one per arm. Everything else in those arms, including the `--dry-run` re-injection, stays identical.)

- [ ] **Step 2: Update installer tests that set `ENG_MCP_SERVER`.** In `src/mcp-install.test.sh`, the tests that drive `main`/`uninstall_main` set `ENG_MCP_SERVER=/x/index.ts` (lines ~82, 85, 88, 237, 244, and any in the uninstall_main block ~165-180). Replace every `ENG_MCP_SERVER=/x/index.ts` with `ENG_MCP_BIN=/x/eng-mcp`.

Run to find them all: `grep -n 'ENG_MCP_SERVER' src/mcp-install.test.sh` — replace each. After: `grep -c 'ENG_MCP_SERVER' src/mcp-install.test.sh` must be `0`.

IMPORTANT: the choose-flow tests (lines ~237, 244) and the uninstall_main `--all` tests register agents in DRY-RUN, so the binary doesn't need to exist for those (dry-run prints before the guard). The non-dry-run uninstall tests call `unregister_agent` (which has no binary guard — uninstall just removes, see Task 2 note) so they're unaffected. Verify no non-dry-run *install* test relies on a fake binary existing; if one does, point its `ENG_MCP_BIN` at a real file (`touch`ed in the temp dir).

- [ ] **Step 3: Run the full suite**

Run: `bash src/mcp-install.test.sh 2>&1 | tail -1`
Expected: all pass, `0 failed`.

- [ ] **Step 4: Verify the eng dispatch end-to-end (dry-run, no mutation)**

Run: `./eng mcp install --dry-run 2>&1 | head -8`
Expected: prints detected agents + `[dry-run] ...: claude mcp add engleader -s user -- <repo>/eng-mcp` style lines (binary path, NOT `bun run`). Nothing mutated.

- [ ] **Step 5: Commit**

```bash
git add eng src/mcp-install.test.sh
git commit -m "feat(eng): export ENG_MCP_BIN for the compiled binary; update tests"
```

---

## Task 6: Release workflow (matrix compile → assets)

**Files:**
- Create: `.github/workflows/mcp-release.yml`

- [ ] **Step 1: Create `.github/workflows/mcp-release.yml`:**

```yaml
name: mcp-release
on:
  push:
    tags: ["v*"]
permissions:
  contents: write
jobs:
  build:
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: macos-latest,   target: bun-darwin-arm64, asset: macos-aarch64 }
          - { os: macos-13,       target: bun-darwin-x64,   asset: macos-x86_64 }
          - { os: ubuntu-latest,  target: bun-linux-x64,    asset: linux-x86_64 }
          - { os: windows-latest, target: bun-windows-x64,  asset: windows-x86_64 }
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v2
      - name: Install deps
        working-directory: mcp
        run: bun install
      - name: Compile
        working-directory: mcp
        shell: bash
        run: bun build index.ts --compile --target=${{ matrix.target }} --outfile eng-mcp${{ runner.os == 'Windows' && '.exe' || '' }}
      - name: Smoke-run (non-Windows)
        if: runner.os != 'Windows'
        working-directory: mcp
        shell: bash
        run: |
          out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ENG_BIN=/bin/true ./eng-mcp 2>/dev/null || true)
          echo "$out" | grep -q eng_lead_time || { echo "smoke test failed: $out"; exit 1; }
      - name: Smoke-run (Windows)
        if: runner.os == 'Windows'
        working-directory: mcp
        shell: bash
        run: |
          out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ENG_BIN=/bin/true ./eng-mcp.exe 2>/dev/null || true)
          echo "$out" | grep -q eng_lead_time || { echo "smoke test failed: $out"; exit 1; }
      - name: Package
        working-directory: mcp
        shell: bash
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          NAME="eng-mcp-v${VERSION}-${{ matrix.asset }}"
          if [ "${{ runner.os }}" = "Windows" ]; then
            7z a "${NAME}.zip" eng-mcp.exe
          else
            tar -czf "${NAME}.tar.gz" eng-mcp
          fi
      - uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ github.ref_name }}
          files: |
            mcp/eng-mcp-v*-*.tar.gz
            mcp/eng-mcp-v*-*.zip
```

- [ ] **Step 2: Validate the workflow YAML locally**

Run: `cd ~/Projects/engleader.tools/engleader-tools-scripts && python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/mcp-release.yml')); print('YAML OK')"`
Expected: `YAML OK`. (If PyYAML isn't installed, instead run `bun -e "console.log('skip')"` and rely on the actionlint check in Step 3.)

- [ ] **Step 3: Lint with actionlint if available (optional but preferred)**

Run: `command -v actionlint >/dev/null && actionlint .github/workflows/mcp-release.yml || echo "actionlint not installed; skipping"`
Expected: no errors, or the skip message.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/mcp-release.yml
git commit -m "ci: matrix-compile eng-mcp and attach per-platform release assets"
```

NOTE: This workflow only runs on GitHub when a `v*` tag is pushed. It is NOT exercised locally. Its real validation is the first tagged release (Task 9 / release process). The local compile (Task 4 Step 2) already proved `bun build --compile` works for the host platform; the matrix just repeats it per-OS.

---

## Task 7: Homebrew formula — stage the eng-mcp binary

**Files:**
- Modify: `~/Projects/recurse/2026/homebrew-tap/Formula/eng-leader-tools.rb`

**Context:** Current formula installs only `src` + `eng`. Add per-platform `resource` blocks for the `eng-mcp` asset and stage into libexec. The `sha256` values can be placeholders for now (`update.sh` fills them once assets exist); use 64 zeros as the placeholder sentinel the existing update.sh recognizes.

- [ ] **Step 1: Edit the formula.** After the `depends_on "jq"` line, add per-platform resources. IMPORTANT: use a **literal hardcoded version string** in the URLs (matching the formula's current `version` value), NOT `#{version}` interpolation. This matches the house pattern in the sibling formulae (whereami.rb, lingua.rb, nearme.rb all hardcode `v0.3.3/whereami-v0.3.3-...`) AND is required for `update.sh`, which version-bumps by string-replacing the literal version — it can't replace a Ruby interpolation. First read the formula's current `version "X.Y.Z"` and use that exact string below in place of `0.3.1`:

```ruby
  on_macos do
    on_arm do
      resource "eng-mcp" do
        url "https://github.com/georgemandis/eng-leader-tools/releases/download/v0.3.1/eng-mcp-v0.3.1-macos-aarch64.tar.gz"
        sha256 "0000000000000000000000000000000000000000000000000000000000000000"
      end
    end
    on_intel do
      resource "eng-mcp" do
        url "https://github.com/georgemandis/eng-leader-tools/releases/download/v0.3.1/eng-mcp-v0.3.1-macos-x86_64.tar.gz"
        sha256 "0000000000000000000000000000000000000000000000000000000000000000"
      end
    end
  end
  on_linux do
    resource "eng-mcp" do
      url "https://github.com/georgemandis/eng-leader-tools/releases/download/v0.3.1/eng-mcp-v0.3.1-linux-x86_64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end
```

(If the formula's current `version` is not `0.3.1`, substitute the real value in BOTH the `download/vX.Y.Z/` and `eng-mcp-vX.Y.Z-` parts of each URL.)

- [ ] **Step 2: Stage the binary in `install`.** Change the `def install` body so it stages the resource. Replace:
```ruby
    libexec.install "src"
    libexec.install "eng"
```
with:
```ruby
    libexec.install "src"
    libexec.install "eng"
    resource("eng-mcp").stage { libexec.install "eng-mcp" }
```

- [ ] **Step 3: Syntax-check the Ruby**

Run: `ruby -c ~/Projects/recurse/2026/homebrew-tap/Formula/eng-leader-tools.rb`
Expected: `Syntax OK`.

- [ ] **Step 4: Commit (placeholder hashes; real hashes filled at release time)**

```bash
cd ~/Projects/recurse/2026/homebrew-tap
git checkout -b mcp-binary-resource
git add Formula/eng-leader-tools.rb
git commit -m "formula: stage compiled eng-mcp binary from per-platform release assets"
```

NOTE: Do NOT push or expect `brew install` to work until the v-next release actually has the assets AND `update.sh` has filled the real resource hashes. This is wired in the release-process task. The `update.sh` hashing fix (already shipped) will hash each resource's URL automatically.

---

## Task 8: Scoop manifest — add the eng-mcp.exe asset

**Files:**
- Modify: `~/Projects/recurse/2026/scoop-bucket/eng-leader-tools.json`

**Context:** The spec calls for Scoop multi-URL. FIRST verify Scoop's multi-URL + extract_dir-array semantics; if they don't behave, fall back per the spec.

- [ ] **Step 1: Branch + verify Scoop multi-URL semantics.** Branch the repo, then confirm the intended shape against Scoop docs/an existing multi-URL manifest if one exists in the bucket:

```bash
cd ~/Projects/recurse/2026/scoop-bucket && git checkout -b mcp-binary-asset
grep -l '"url": \[' *.json 2>/dev/null || echo "no existing multi-url manifest to copy"
```
Expected: either an example to mirror, or the note. Multi-URL Scoop manifests use `"url": [a, b]`, `"hash": [ha, hb]`, and `"extract_dir": [da, db]` applied index-wise. Document what you confirm in the commit message.

- [ ] **Step 2: Edit the manifest** to the multi-URL shape (placeholder hash for the new asset; update.sh fills it). Change the flat `url`/`hash`/`extract_dir` to arrays:

```json
    "url": [
        "https://github.com/georgemandis/eng-leader-tools/archive/refs/tags/v0.3.1.tar.gz",
        "https://github.com/georgemandis/eng-leader-tools/releases/download/v0.3.1/eng-mcp-v0.3.1-windows-x86_64.zip"
    ],
    "hash": [
        "901e5fa74298a4a1621d1b71c5f992637b7f117a4b6459ef960b3ca768aae4c4",
        "0000000000000000000000000000000000000000000000000000000000000000"
    ],
    "extract_dir": [
        "eng-leader-tools-0.3.1",
        ""
    ],
```

(The version numbers here are illustrative of the CURRENT version; the next release's update.sh bumps them. Keep `bin` as `"eng"`. The autoupdate block's `url` only covers the source tarball today — note in the commit that autoupdate for the second URL is handled by the fixed update.sh, which rewrites whichever URL fields exist.)

- [ ] **Step 3: Validate JSON**

Run: `python3 -c "import json; json.load(open('eng-leader-tools.json')); print('valid JSON')"`
Expected: `valid JSON`.

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/recurse/2026/scoop-bucket
git add eng-leader-tools.json
git commit -m "manifest: add compiled eng-mcp.exe via multi-URL (placeholder hash)"
```

NOTE: Like Homebrew, don't expect `scoop install` to work until the release has the asset and update.sh fills the real hash.

---

## Task 9: Document the new release process

**Files:**
- Modify: `~/Projects/engleader.tools/engleader-tools-scripts/ROADMAP.md` (or create `RELEASING.md`)

**Context:** The release now depends on CI-built assets. Capture the ordering so a future release doesn't point manifests at not-yet-built assets.

- [ ] **Step 1: Create `RELEASING.md`** at the source repo root with the exact order:

```markdown
# Releasing

1. Bump `VERSION` in `eng`, commit.
2. Tag `vX.Y.Z` and push the tag: `git push origin vX.Y.Z`.
3. The `mcp-release.yml` workflow compiles `eng-mcp` for all platforms and
   attaches `eng-mcp-vX.Y.Z-<asset>.{tar.gz,zip}` to the release. **Wait for it
   to finish** (check the Actions tab).
4. Ensure the GitHub release exists for the tag (the workflow attaches to it; or
   run `gh release create vX.Y.Z --generate-notes`).
5. ONLY after assets exist: in homebrew-tap and scoop-bucket, run
   `./update.sh eng-leader-tools` (fills the source-tarball hash AND the
   per-platform eng-mcp asset hashes — the URLs are hashed directly, so the
   assets must be present first), then commit + push each.
6. Verify: `brew update && brew upgrade eng-leader-tools`; confirm
   `libexec/eng-mcp` exists and `eng mcp install --dry-run` shows the binary path.
```

- [ ] **Step 2: Commit**

```bash
cd ~/Projects/engleader.tools/engleader-tools-scripts
git add RELEASING.md
git commit -m "docs: document the compiled-binary release process"
```

---

## Task 10: Full source-repo verification sweep

**Files:** none (verification only)

- [ ] **Step 1: Installer + server tests**

Run: `cd ~/Projects/engleader.tools/engleader-tools-scripts && bash src/mcp-install.test.sh 2>&1 | tail -1 && (cd mcp && bun test 2>&1 | grep -E '^ [0-9]+ (pass|fail)')`
Expected: installer `0 failed`; server `0 fail`.

- [ ] **Step 2: No stale references**

Run: `grep -rn 'ENG_MCP_SERVER\|mcp_server_path\|bun run.*index.ts' eng src/mcp-install.sh src/mcp-install.test.sh || echo "clean — no stale references"`
Expected: `clean — no stale references`.

- [ ] **Step 3: eng mcp build produces a working binary, end-to-end**

Run:
```bash
cd ~/Projects/engleader.tools/engleader-tools-scripts
./eng mcp build
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ENG_BIN=/bin/true ./eng-mcp 2>/dev/null | grep -o '"eng_[a-z_]*"' | sort -u | wc -l | tr -d ' '
rm -f eng-mcp
```
Expected: `13` (the freshly built binary lists 13 tools).

- [ ] **Step 4: Installer registers the built binary (dry-run shows the path)**

Run: `./eng mcp install --dry-run 2>&1 | grep -E '\[dry-run\]|registered|not registered' | head`
Expected: dry-run lines reference the `eng-mcp` binary path (or "no agents" if none detected) — never `bun run`.

- [ ] **Step 5: Syntax sweep**

Run: `bash -n eng && bash -n src/mcp-install.sh && echo "syntax OK"`
Expected: `syntax OK`.

---

## Self-Review Notes

- **Spec coverage:** release workflow (Task 6) ✓; `eng mcp build` + package.json (Task 4) ✓; binary resolution `mcp_bin_path`/`ENG_MCP_BIN` (Tasks 1,5) ✓; registration shape `{command:<bin>,args:[]}` + missing-binary guard (Tasks 2,3) ✓; Homebrew resource staging (Task 7) ✓; Scoop multi-URL (Task 8) ✓; release-order doc (Task 9) ✓; test updates (Tasks 1-3,5) ✓; verification (Task 10) ✓. Out-of-scope items (linux-arm64, signing, npm, bin symlink) honored.
- **Placeholder scan:** The 64-zero sha256/hash in Tasks 7-8 are intentional release-time-filled sentinels (the existing update.sh recognizes `0{64}` to force re-hash), documented as such — not lazy placeholders. No TBD/TODO elsewhere.
- **Consistency:** `mcp_bin_path` / `ENG_MCP_BIN` / `eng-mcp` / `{command:<bin>,args:[]}` used consistently across Tasks 1-8. The `register_agent`/`merge_json_config` 2nd arg is `bin` everywhere after Tasks 2-3. The dispatch arms export `ENG_MCP_BIN` (Task 5) matching `mcp_bin_path`'s override (Task 1).
- **Mid-refactor red states:** Tasks 1-3 deliberately sequence a rename→register→json-shape progression; Steps note where an assertion is temporarily expected to lag until the next task. Task 10 is the clean all-green gate.
- **Three-repo logistics:** source on `mcp-compiled-binary`; homebrew-tap branches in Task 7; scoop-bucket branches in Task 8. Tap/bucket changes carry placeholder hashes and are NOT pushed until the release process (real assets + update.sh).
