# `eng mcp uninstall` Design

## Problem

`eng mcp install` registers the engleader MCP server into a user's AI agents
(Claude Code via CLI; Cursor, VS Code, Gemini, Codex, Windsurf, OpenCode via a
JSON config merge). There is currently no supported way to undo a registration
— a user who wants to remove engleader must hand-edit each agent's config or run
`claude mcp remove` themselves. We want a first-class `eng mcp uninstall` that
mirrors `install` in reverse.

## Solution

Add an `uninstall` subcommand to the existing installer (`src/mcp-install.sh`)
and the existing `eng mcp` dispatch arm. It finds which agents actually have
`engleader` registered, prompts which to remove from, and surgically deletes
only our entry — never touching peer MCP servers or other config keys.

The design reuses the install machinery: `detect_agents`, the flag-parsing
shape, the dry-run convention, and the interactive prompt structure. It adds
three functions (`agent_has_engleader`, `unregister_agent`, `uninstall_main`)
and one dispatch sub-arm.

Key asymmetry from install: uninstall does **not** write a `.bak` backup. The
removal is trivially reversible with `eng mcp install`, so the backup clutter
isn't worth it. The JSON edit is still atomic (write `.tmp`, then `mv`) so a
failure mid-write cannot corrupt the config.

## Components (all in `src/mcp-install.sh`)

### `agent_has_engleader "<name|kind|path>"`

The "is-registered" probe. Returns success (exit 0) only if `engleader` is
registered for that agent:

- `cli` (Claude Code): `claude mcp get engleader >/dev/null 2>&1`. If `claude
  mcp get` is unavailable in the installed CLI version, fall back to
  `claude mcp list 2>/dev/null | grep -q '^engleader\b'`.
- `json`: `jq -e '.mcpServers.engleader' "$path" >/dev/null 2>&1` — true only if
  the key exists and is non-null. The `-e` flag makes jq's exit status reflect
  the query result. A missing or unreadable file returns non-zero (not
  registered), which is correct.

### `unregister_agent "<name|kind|path>"`

Mirror of `register_agent`. Honors `ENG_MCP_DRY_RUN=1` (print intended action,
change nothing):

- dry-run, `cli`: `echo "[dry-run] $name: claude mcp remove engleader -s user"`
- dry-run, `json`: `echo "[dry-run] $name: remove engleader from $path"`
- `cli`: `claude mcp remove engleader -s user` → `✓ $name: engleader removed`
  on success, `✗ $name: claude mcp remove failed` to stderr on failure.
- `json`: atomic surgical delete —
  `jq 'del(.mcpServers.engleader)' "$path" > "${path}.tmp" && mv "${path}.tmp" "$path"`
  → `✓ $name: engleader removed ($path)` / `✗ $name: failed to update $path`
  to stderr on failure. **No backup.** `del()` targets exactly
  `.mcpServers.engleader`; sibling servers, other top-level keys, and an empty
  `.mcpServers` object (if engleader was the sole entry) are all left untouched.
- unknown kind: `✗ $name: unknown registration kind '$kind', skipped` to stderr.

### `uninstall_main()`

Mirror of `main()`:

1. Parse flags identically to `main`: `--all`, `--agent <name>` and
   `--agent=name`, `--dry-run`, `-h`/`--help` (prints usage, returns 0).
   `[[ -n "$dry_run" ]] && export ENG_MCP_DRY_RUN=1`.
2. Run `detect_agents`, then filter each detected line through
   `agent_has_engleader` to build the **registered set** (only agents that
   actually have engleader).
3. If the registered set is empty → print
   `engleader is not registered in any detected agent.` and `return 0`
   (nothing to do is success, not an error).
4. Print `engleader is registered in:` followed by the registered agent names.
5. Non-interactive paths:
   - `--agent <name>`: exact first-field match against the **registered** set
     (reuse the `${line%%|*}` exact-match pattern from `main`). If not in the
     registered set → `Agent '<name>' does not have engleader registered.` to
     stderr, `return 1`. Else `unregister_agent`.
   - `--all`: `unregister_agent` for every line in the registered set.
6. Interactive: prompt `Remove from which? [a]ll / [c]hoose / [q]uit:`; `all`
   removes from every registered agent; `choose` prompts per-agent `y/N`; `quit`
   aborts.

## Dispatch (`eng`)

In the existing `mcp)` arm, add an `uninstall)` sub-arm alongside `install)`,
structured identically:

```bash
      uninstall)
        shift 2>/dev/null || true
        export ENG_MCP_SERVER="${SCRIPT_DIR}/mcp/index.ts"
        if [[ "$_dry_run" == "true" ]]; then
          exec bash "${SCRIPT_DIR}/src/mcp-install.sh" uninstall "$@" --dry-run
        fi
        exec bash "${SCRIPT_DIR}/src/mcp-install.sh" uninstall "$@"
        ;;
```

(The `ENG_MCP_SERVER` export is harmless for uninstall — the path isn't used by
the removal logic, but exporting it keeps the two sub-arms identical.)

`src/mcp-install.sh`'s entry point must route the `uninstall` first argument to
`uninstall_main` (and `install`/absent to `main`). The current file runs `main
"$@"` under the `ENG_MCP_LIB` guard; update that guard to dispatch on `$1`:

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

(When invoked by `eng`, the first arg is `install` or `uninstall`. When invoked
directly with only flags, the first arg is neither, so `main "$@"` runs with the
flags intact — preserving the existing behavior.)

Update the `eng mcp -h|--help|help|""` usage line to:

```
Usage: eng mcp <install|uninstall> [--all] [--agent <name>] [--dry-run]
```

## Error Handling

- Nothing registered → friendly message, `return 0`.
- `--agent <name>` not in the registered set → error to stderr, `return 1`.
- `claude mcp remove` or the jq delete fails → `✗ <name>: ...` to stderr,
  continue with the other selected agents (don't abort the whole run).
- Atomic write: jq writes to `${path}.tmp` and only `mv`s on success, so a jq
  failure leaves the original config intact.

## Testing

Append to `src/mcp-install.test.sh`, reusing the existing fake-HOME / fake-claude
harness and the `ok` assertion helper:

- `agent_has_engleader` returns true when `.mcpServers.engleader` is present in
  a json config, false when absent, false for a missing file.
- `unregister_agent` (json) deletes `engleader` and **preserves a peer entry**:
  given `{"mcpServers":{"engleader":{...},"engsight":{...}},"other":1}`, after
  removal `engsight` and `other` remain, `engleader` is gone.
- `unregister_agent` (json) leaves an empty `mcpServers` object when engleader
  was the sole entry (does not prune it).
- `unregister_agent` dry-run mutates nothing (config unchanged).
- `unregister_agent` (cli) invokes `claude mcp remove engleader` (assert via a
  fake `claude` that logs its args).
- `uninstall_main --agent <name>` removes from that one agent only.
- `uninstall_main --all` removes from all registered agents.
- `uninstall_main --agent <bogus-or-unregistered>` errors with non-zero exit.
- `uninstall_main` with nothing registered prints the friendly message and
  returns 0.

## Out of Scope (YAGNI)

- Pruning leftover `*.bak-*` files created by install (separate concern; user
  can delete them manually).
- Pruning an empty `.mcpServers` object (we standardize on surgical key deletion
  to avoid mutating a container key we didn't create).
- Removing engleader from agents that aren't currently detected (if the agent's
  CLI/config is gone, there's nothing to act on).
