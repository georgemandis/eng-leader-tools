# `eng mcp uninstall` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `eng mcp uninstall` subcommand that finds which AI agents have the engleader MCP server registered and surgically removes only that entry, mirroring `eng mcp install` in reverse.

**Architecture:** Three new bash functions in the existing `src/mcp-install.sh` (`agent_has_engleader`, `unregister_agent`, `uninstall_main`) plus an `uninstall)` sub-arm in the `eng` `mcp)` dispatch and an updated entry-point guard. Reuses the install machinery: `detect_agents`, the flag-parsing/interactive shapes, and the dry-run convention. JSON removal is a surgical `jq 'del(.mcpServers.engleader)'` with an atomic `.tmp`+`mv` write and no backup (reversible via reinstall).

**Tech Stack:** Bash, `jq` (already a project dependency), plain-shell test runner (`src/mcp-install.test.sh`).

**Spec:** [`docs/superpowers/specs/2026-06-17-mcp-uninstall-design.md`](../specs/2026-06-17-mcp-uninstall-design.md)

---

## File Structure

**Modify:**
- `src/mcp-install.sh` — add `agent_has_engleader`, `unregister_agent`, `uninstall_main` (after the existing `register_agent`/`main`, before the entry-point guard); update the entry-point guard to dispatch `uninstall` vs `install`.
- `src/mcp-install.test.sh` — append uninstall tests before the final `echo "----"` summary block (which must remain last).
- `eng` — add an `uninstall)` sub-arm to the `mcp)` dispatch; update the `eng mcp` help/usage line.

**Responsibilities unchanged:** `src/mcp-install.sh` remains the single installer/uninstaller library; `eng` remains the dispatcher. No new files — the uninstall logic is the symmetric complement of install and belongs beside it.

**Conventions to follow (from the existing file):**
- `set -uo pipefail` (NOT -e) — conditional `&&`/`||` chains depend on this.
- Functions are sourced in library mode via `ENG_MCP_LIB=1`; the entry-point guard at the file end runs only when not sourced.
- Test harness: `ok "<desc>" '<bash test expr>'`, fake `$HOME` + fake `claude` on `PATH`, temp dirs cleaned with `rm -rf`. Summary lines `echo "----"; echo "$PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]` stay at the very end.

---

## Task 1: `agent_has_engleader` probe

**Files:**
- Modify: `src/mcp-install.sh` (add function before the entry-point guard `if [[ -z "${ENG_MCP_LIB:-}" ]]; then`)
- Test: `src/mcp-install.test.sh` (append before the final `echo "----"` block)

- [ ] **Step 1: Append the failing tests** to `src/mcp-install.test.sh` before the `echo "----"` line:

```bash
# --- agent_has_engleader probe ---
HTMP="$(mktemp -d)"
has_cfg="$HTMP/has.json";  echo '{"mcpServers":{"engleader":{"command":"bun"}}}' > "$has_cfg"
no_cfg="$HTMP/no.json";    echo '{"mcpServers":{"other":{"command":"x"}}}'        > "$no_cfg"

ok "agent_has_engleader true when engleader present" 'agent_has_engleader "cursor|json|$has_cfg"'
ok "agent_has_engleader false when engleader absent" '! agent_has_engleader "cursor|json|$no_cfg"'
ok "agent_has_engleader false when file missing" '! agent_has_engleader "cursor|json|$HTMP/nope.json"'
rm -rf "$HTMP"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash src/mcp-install.test.sh`
Expected: FAIL — `agent_has_engleader: command not found` on the new lines.

- [ ] **Step 3: Add the function** to `src/mcp-install.sh`, immediately before the entry-point guard:

```bash
# agent_has_engleader <"name|kind|path">
#   Returns 0 only if engleader is currently registered for that agent.
agent_has_engleader() {
  local entry="$1"
  local name kind path
  IFS='|' read -r name kind path <<<"$entry"
  case "$kind" in
    cli)
      claude mcp get engleader >/dev/null 2>&1 && return 0
      claude mcp list 2>/dev/null | grep -q '^engleader\b' && return 0
      return 1
      ;;
    json)
      [[ -f "$path" ]] || return 1
      jq -e '.mcpServers.engleader' "$path" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash src/mcp-install.test.sh`
Expected: `22 passed, 0 failed` (19 existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add src/mcp-install.sh src/mcp-install.test.sh
git commit -m "feat(mcp): agent_has_engleader probe for uninstall"
```

Note: the `cli` branch is exercised by Task 3's flow tests with a fake `claude`; here we test the `json` and missing-file branches directly (no fake `claude` needed for those).

---

## Task 2: `unregister_agent`

**Files:**
- Modify: `src/mcp-install.sh` (add function before the entry-point guard)
- Test: `src/mcp-install.test.sh` (append before the final `echo "----"` block)

- [ ] **Step 1: Append the failing tests** to `src/mcp-install.test.sh` before the `echo "----"` line:

```bash
# --- unregister_agent (json) ---
UTMP="$(mktemp -d)"
ucfg="$UTMP/mcp.json"
echo '{"mcpServers":{"engleader":{"command":"bun"},"engsight":{"command":"x"}},"other":1}' > "$ucfg"

unregister_agent "cursor|json|$ucfg" >/dev/null
ok "unregister removes engleader" '! jq -e ".mcpServers.engleader" "$ucfg" >/dev/null 2>&1'
ok "unregister preserves peer engsight" 'jq -e ".mcpServers.engsight" "$ucfg" >/dev/null 2>&1'
ok "unregister preserves other top-level key" '[[ "$(jq -r ".other" "$ucfg")" == "1" ]]'

# sole entry -> leaves empty mcpServers object (no pruning)
solecfg="$UTMP/sole.json"
echo '{"mcpServers":{"engleader":{"command":"bun"}}}' > "$solecfg"
unregister_agent "cursor|json|$solecfg" >/dev/null
ok "unregister leaves empty mcpServers object" '[[ "$(jq -c ".mcpServers" "$solecfg")" == "{}" ]]'

# no backup file is created
ok "unregister creates no backup" '! ls "$ucfg".bak-* >/dev/null 2>&1'

# dry-run mutates nothing
drycfg="$UTMP/dry.json"
echo '{"mcpServers":{"engleader":{"command":"bun"}}}' > "$drycfg"
ENG_MCP_DRY_RUN=1 unregister_agent "cursor|json|$drycfg" >/dev/null
ok "dry-run leaves engleader in place" 'jq -e ".mcpServers.engleader" "$drycfg" >/dev/null 2>&1'

# cli path invokes claude mcp remove (fake claude logs args)
ufb="$UTMP/bin"; mkdir -p "$ufb"
cat > "$ufb/claude" <<'EOF'
#!/bin/sh
echo "$@" >> "$CLAUDE_LOG"
EOF
chmod +x "$ufb/claude"
CLAUDE_LOG="$UTMP/claude.log" PATH="$ufb:$PATH" \
  unregister_agent "claude-code|cli|" >/dev/null
ok "cli unregister invokes claude mcp remove engleader" 'grep -q "mcp remove engleader" "$UTMP/claude.log"'

rm -rf "$UTMP"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash src/mcp-install.test.sh`
Expected: FAIL — `unregister_agent: command not found`.

- [ ] **Step 3: Add the function** to `src/mcp-install.sh`, before the entry-point guard:

```bash
# unregister_agent <"name|kind|path">
#   Removes the engleader registration. Honors ENG_MCP_DRY_RUN=1.
#   JSON removal is surgical (only .mcpServers.engleader) and atomic
#   (.tmp + mv); no backup — re-add with `eng mcp install`.
unregister_agent() {
  local entry="$1"
  local name kind path
  IFS='|' read -r name kind path <<<"$entry"

  if [[ -n "${ENG_MCP_DRY_RUN:-}" ]]; then
    if [[ "$kind" == "cli" ]]; then
      echo "[dry-run] $name: claude mcp remove engleader -s user"
    else
      echo "[dry-run] $name: remove engleader from $path"
    fi
    return 0
  fi

  case "$kind" in
    cli)
      claude mcp remove engleader -s user \
        && echo "✓ $name: engleader removed" \
        || echo "✗ $name: claude mcp remove failed" >&2
      ;;
    json)
      jq 'del(.mcpServers.engleader)' "$path" > "${path}.tmp" \
        && mv "${path}.tmp" "$path" \
        && echo "✓ $name: engleader removed ($path)" \
        || echo "✗ $name: failed to update $path" >&2
      ;;
    *)
      echo "✗ $name: unknown registration kind '$kind', skipped" >&2
      ;;
  esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash src/mcp-install.test.sh`
Expected: `29 passed, 0 failed` (22 + 7 new).

- [ ] **Step 5: Commit**

```bash
git add src/mcp-install.sh src/mcp-install.test.sh
git commit -m "feat(mcp): unregister_agent surgical removal (no backup, atomic)"
```

---

## Task 3: `uninstall_main` flow

**Files:**
- Modify: `src/mcp-install.sh` (add function before the entry-point guard)
- Test: `src/mcp-install.test.sh` (append before the final `echo "----"` block)

- [ ] **Step 1: Append the failing tests** to `src/mcp-install.test.sh` before the `echo "----"` line:

```bash
# --- uninstall_main flow ---
NTMP="$(mktemp -d)"
# fake claude that reports engleader as registered and logs removes
nfb="$NTMP/bin"; mkdir -p "$nfb"
cat > "$nfb/claude" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "mcp get") exit 0 ;;            # engleader is registered
  "mcp remove") echo "removed $3" >> "$CLAUDE_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$nfb/claude"

# cursor present WITH engleader; opencode present WITHOUT engleader
mkdir -p "$NTMP/.cursor";          echo '{"mcpServers":{"engleader":{"command":"bun"}}}' > "$NTMP/.cursor/mcp.json"
mkdir -p "$NTMP/.config/opencode"; echo '{"mcpServers":{"other":{"command":"x"}}}'        > "$NTMP/.config/opencode/opencode.json"

# --all removes from registered agents only (cursor + claude), not opencode
CLAUDE_LOG="$NTMP/c.log" HOME="$NTMP" PATH="$nfb:$PATH" uninstall_main --all >/dev/null 2>&1
ok "uninstall --all removes engleader from cursor" '! jq -e ".mcpServers.engleader" "$NTMP/.cursor/mcp.json" >/dev/null 2>&1'
ok "uninstall --all calls claude mcp remove" 'grep -q "removed engleader" "$NTMP/c.log"'
ok "uninstall --all leaves opencode (no engleader) untouched" 'jq -e ".mcpServers.other" "$NTMP/.config/opencode/opencode.json" >/dev/null 2>&1'

# --agent targeting a registered agent
echo '{"mcpServers":{"engleader":{"command":"bun"}}}' > "$NTMP/.cursor/mcp.json"
HOME="$NTMP" PATH="$nfb:$PATH" uninstall_main --agent cursor >/dev/null 2>&1
ok "uninstall --agent cursor removes from cursor" '! jq -e ".mcpServers.engleader" "$NTMP/.cursor/mcp.json" >/dev/null 2>&1'

# --agent for an agent without engleader -> error, non-zero
HOME="$NTMP" PATH="$nfb:$PATH" uninstall_main --agent opencode >/dev/null 2>&1; rc=$?
ok "uninstall --agent opencode (unregistered) errors" '[[ "$rc" -ne 0 ]]'

# --dry-run mutates nothing
echo '{"mcpServers":{"engleader":{"command":"bun"}}}' > "$NTMP/.cursor/mcp.json"
HOME="$NTMP" PATH="$nfb:$PATH" uninstall_main --all --dry-run >/dev/null 2>&1
ok "uninstall --dry-run leaves cursor engleader in place" 'jq -e ".mcpServers.engleader" "$NTMP/.cursor/mcp.json" >/dev/null 2>&1'

# nothing registered -> friendly message + exit 0
ETMP="$(mktemp -d)"
efb="$ETMP/bin"; mkdir -p "$efb"
cat > "$efb/claude" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$efb/claude"
mkdir -p "$ETMP/.cursor"; echo '{"mcpServers":{"other":{"command":"x"}}}' > "$ETMP/.cursor/mcp.json"
OUT_NONE="$(HOME="$ETMP" PATH="$efb:$PATH" uninstall_main --all 2>&1)"; rc=$?
ok "uninstall with nothing registered returns 0" '[[ "$rc" -eq 0 ]]'
ok "uninstall with nothing registered says so" '[[ "$OUT_NONE" == *"not registered in any"* ]]'
rm -rf "$ETMP"

rm -rf "$NTMP"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash src/mcp-install.test.sh`
Expected: FAIL — `uninstall_main: command not found`.

- [ ] **Step 3: Add the function** to `src/mcp-install.sh`, before the entry-point guard. This mirrors `main()`'s flag parsing and interactive structure, but filters the detected set through `agent_has_engleader` and calls `unregister_agent`:

```bash
# uninstall_main [--all] [--agent <name>] [--dry-run]
#   Removes engleader from agents that currently have it registered.
uninstall_main() {
  local dry_run="" target_agent="" remove_all=""
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=1 ;;
      --all) remove_all=1 ;;
      --agent) ;; # value handled below
      --agent=*) target_agent="${arg#--agent=}" ;;
      -h|--help)
        echo "Usage: eng mcp uninstall [--all] [--agent <name>] [--dry-run]"
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

  # Build the registered set: detected agents that actually have engleader.
  local registered=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if agent_has_engleader "$line"; then
      registered+="${line}"$'\n'
    fi
  done <<<"$(detect_agents)"
  registered="${registered%$'\n'}"

  if [[ -z "$registered" ]]; then
    echo "engleader is not registered in any detected agent."
    return 0
  fi

  echo "engleader is registered in:"
  while IFS='|' read -r name kind path; do
    [[ -z "$name" ]] && continue
    echo "  - $name${path:+  ($path)}"
  done <<<"$registered"
  echo

  # Non-interactive paths
  if [[ -n "$target_agent" ]]; then
    local entry=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "${line%%|*}" == "$target_agent" ]]; then entry="$line"; break; fi
    done <<<"$registered"
    [[ -z "$entry" ]] && { echo "Agent '$target_agent' does not have engleader registered." >&2; return 1; }
    unregister_agent "$entry"
    return 0
  fi
  if [[ -n "$remove_all" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      unregister_agent "$entry"
    done <<<"$registered"
    return 0
  fi

  # Interactive
  printf "Remove from which? [a]ll / [c]hoose / [q]uit: "
  read -r choice
  case "$choice" in
    a|A)
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        unregister_agent "$entry"
      done <<<"$registered" ;;
    c|C)
      while IFS='|' read -r name kind path; do
        [[ -z "$name" ]] && continue
        printf "Remove from %s? [y/N]: " "$name"
        read -r yn
        [[ "$yn" == "y" || "$yn" == "Y" ]] && unregister_agent "$name|$kind|$path"
      done <<<"$registered" ;;
    *)
      echo "Aborted." ;;
  esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash src/mcp-install.test.sh`
Expected: `37 passed, 0 failed` (29 + 8 new).

- [ ] **Step 5: Commit**

```bash
git add src/mcp-install.sh src/mcp-install.test.sh
git commit -m "feat(mcp): uninstall_main flow (registered-set filtering, parity flags)"
```

---

## Task 4: Entry-point dispatch (install vs uninstall)

**Files:**
- Modify: `src/mcp-install.sh` (the entry-point guard at the end of the file)
- Test: `src/mcp-install.test.sh` (append before the final `echo "----"` block)

The file currently ends with:

```bash
if [[ -z "${ENG_MCP_LIB:-}" ]]; then
  main "$@"
fi
```

This must route an `uninstall` first argument to `uninstall_main`. Because the tests source the file with `ENG_MCP_LIB=1`, the guard body never runs under test — so we test it by invoking the script as a subprocess in library-bypass mode.

- [ ] **Step 1: Append the failing tests** to `src/mcp-install.test.sh` before the `echo "----"` line:

```bash
# --- entry-point dispatch (subprocess, not sourced) ---
DTMP="$(mktemp -d)"
dfb="$DTMP/bin"; mkdir -p "$dfb"
cat > "$dfb/claude" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$dfb/claude"
# No agents have engleader, so both paths short-circuit with a recognizable line.

OUT_UNINST="$(HOME="$DTMP" PATH="$dfb:$PATH" bash "$SCRIPT_DIR/mcp-install.sh" uninstall --all 2>&1)"
ok "entry dispatch: 'uninstall' reaches uninstall_main" '[[ "$OUT_UNINST" == *"not registered in any"* ]]'

OUT_INST="$(HOME="$DTMP" PATH="$dfb:$PATH" bash "$SCRIPT_DIR/mcp-install.sh" install --all 2>&1)"
ok "entry dispatch: 'install' reaches main" '[[ "$OUT_INST" == *"No supported agents detected"* || "$OUT_INST" == *"Detected agents"* ]]'

OUT_BARE="$(HOME="$DTMP" PATH="$dfb:$PATH" bash "$SCRIPT_DIR/mcp-install.sh" --dry-run 2>&1)"
ok "entry dispatch: bare flags still reach main" '[[ "$OUT_BARE" == *"No supported agents detected"* || "$OUT_BARE" == *"Detected agents"* ]]'
rm -rf "$DTMP"
```

Note on the `install`/bare cases: with no detected agents, `main` prints "No supported agents detected"; if the test machine happens to have a real agent config under the temp HOME it would print "Detected agents" instead — the assertion accepts either, so it's deterministic regardless. The temp HOME has no cursor/opencode/etc. configs and a failing fake `claude`, so in practice "No supported agents detected" is what prints.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash src/mcp-install.test.sh`
Expected: FAIL — the `uninstall` case prints `main`'s "No supported agents detected" (because the current guard always calls `main`), so `OUT_UNINST` does NOT contain "not registered in any". (The install/bare cases already pass.)

- [ ] **Step 3: Update the entry-point guard** in `src/mcp-install.sh`:

```bash
if [[ -z "${ENG_MCP_LIB:-}" ]]; then
  if [[ "${1:-}" == "uninstall" ]]; then
    shift; uninstall_main "$@"
  else
    [[ "${1:-}" == "install" ]] && shift
    main "$@"
  fi
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash src/mcp-install.test.sh`
Expected: `40 passed, 0 failed` (37 + 3 new).

- [ ] **Step 5: Commit**

```bash
git add src/mcp-install.sh src/mcp-install.test.sh
git commit -m "feat(mcp): entry-point dispatch for install vs uninstall"
```

---

## Task 5: Wire `eng mcp uninstall` into the eng CLI

**Files:**
- Modify: `eng` (the `mcp)` dispatch arm: add `uninstall)` sub-arm; update the help/usage line)

First READ the `mcp)` arm in `eng` (search for `mcp)`). It currently has `install)`, `-h|--help|help|""`, and `*)` sub-arms. The `install)` arm looks like:

```bash
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
```

- [ ] **Step 1: Add the `uninstall)` sub-arm** immediately after the `install)` arm's closing `;;` (before the `-h|--help|help|""` arm). It mirrors `install)` but passes `uninstall` as the first arg to the script:

```bash
      uninstall)
        shift 2>/dev/null || true
        export ENG_MCP_SERVER="${SCRIPT_DIR}/mcp/index.ts"
        # --dry-run is stripped by eng's global pre-processing; re-add it.
        if [[ "$_dry_run" == "true" ]]; then
          exec bash "${SCRIPT_DIR}/src/mcp-install.sh" uninstall "$@" --dry-run
        fi
        exec bash "${SCRIPT_DIR}/src/mcp-install.sh" uninstall "$@"
        ;;
```

IMPORTANT: the `install)` arm execs the script WITHOUT an explicit `install` first arg (the entry-point guard's `else` branch handles a missing/non-uninstall first arg by running `main`). The `uninstall)` arm MUST pass the literal `uninstall` as the first arg so the entry-point guard routes to `uninstall_main`. Keep `install)` as-is; do not add `install` to it.

- [ ] **Step 2: Update the `eng mcp` help/usage line.** Find the `-h|--help|help|""` arm inside `mcp)` — it currently prints:

```bash
        echo "Usage: eng mcp install [--all] [--agent <name>] [--dry-run]"
```

Replace that single line with:

```bash
        echo "Usage: eng mcp <install|uninstall> [--all] [--agent <name>] [--dry-run]"
```

- [ ] **Step 3: Verify the wiring** (run these):

1. Syntax: `bash -n eng` → no output.

2. mcp help shows uninstall:
   `./eng mcp --help`
   Expect: `Usage: eng mcp <install|uninstall> [--all] [--agent <name>] [--dry-run]`

3. uninstall reaches the installer in dry-run (NO mutation — dry-run only prints). This runs against your real HOME but only prints:
   `./eng mcp uninstall --dry-run`
   Expect: either `engleader is registered in:` + `[dry-run] ... remove ...` lines (if you currently have engleader registered somewhere), OR `engleader is not registered in any detected agent.` Confirm NOTHING was mutated. Paste the output.

4. uninstall help subcommand:
   `./eng mcp uninstall --help`
   Expect: `Usage: eng mcp uninstall [--all] [--agent <name>] [--dry-run]` (this comes from `uninstall_main`'s own -h handler).

5. Regression — install still works:
   `./eng mcp install --dry-run`
   Expect: unchanged behavior (detected agents + `[dry-run]` install lines, or "No supported agents detected").

6. Regression — a normal metric command still dispatches:
   `./eng lead-time --help 2>&1 | head -2`
   Expect: lead-time usage (proves the mcp arm didn't break normal dispatch).

- [ ] **Step 4: Commit**

```bash
git add eng
git commit -m "feat(eng): add 'eng mcp uninstall' subcommand"
```

---

## Task 6: Docs + full sweep

**Files:**
- Modify: `mcp/README.md` (mention uninstall under Install/Usage)
- Verification only otherwise.

- [ ] **Step 1: Add an uninstall note to `mcp/README.md`.** In the `## Install` section, after the existing fenced block listing the `eng mcp install` variants, add:

```markdown
To remove it again:

    eng mcp uninstall            # interactive
    eng mcp uninstall --all      # remove from every agent that has it
    eng mcp uninstall --dry-run  # show what would be removed
```

(Use indented code, matching the style already used elsewhere in that file.)

- [ ] **Step 2: Run the full installer test suite**

Run: `bash src/mcp-install.test.sh`
Expected: `40 passed, 0 failed`.

- [ ] **Step 3: Confirm the MCP server tests are unaffected** (we didn't touch them, but verify nothing regressed)

Run: `cd mcp && bun test`
Expected: `20 pass, 0 fail`.

- [ ] **Step 4: Syntax-check the modified shell files**

Run: `bash -n src/mcp-install.sh && bash -n eng && echo "syntax OK"`
Expected: `syntax OK`

- [ ] **Step 5: Commit**

```bash
git add mcp/README.md
git commit -m "docs(mcp): document eng mcp uninstall"
```

---

## Self-Review Notes

- **Spec coverage:** `agent_has_engleader` (Task 1) ✓; `unregister_agent` surgical/atomic/no-backup/dry-run/peer-preserving (Task 2) ✓; `uninstall_main` registered-set filtering, parity flags, interactive, nothing-registered→0, bad-agent→1 (Task 3) ✓; entry-point dispatch (Task 4) ✓; `eng` `uninstall)` arm + `--dry-run` re-injection + help line (Task 5) ✓; docs (Task 6) ✓. Out-of-scope items (no .bak pruning, no empty-mcpServers pruning) honored — Task 2 explicitly tests that the empty object is left.
- **Placeholder scan:** No TBD/TODO; every code step is complete bash.
- **Naming/type consistency:** `agent_has_engleader`, `unregister_agent`, `uninstall_main`, the `name|kind|path` entry format, `ENG_MCP_DRY_RUN`, and the `registered` set var are used consistently across Tasks 1-5. The `eng` arm passes the literal `uninstall` matching the entry-point guard's `"${1:-}" == "uninstall"` check.
- **Cumulative test counts:** 19 (existing) → 22 → 29 → 37 → 40. Stated per task.
