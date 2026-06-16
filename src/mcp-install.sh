#!/usr/bin/env bash
#
# mcp-install.sh — install the engleader MCP server into AI agents.
# Dispatched as `eng mcp`. Detects installed agents, prompts, registers.
#
# Note: intentionally NOT using -e. Detection and registration rely on
# `cmd && echo ok || echo fail` and `test && echo ...` short-circuits that
# would abort the script under `set -e`.
set -uo pipefail

# Path to the MCP server entrypoint, resolved relative to this script.
# eng exports ENG_MCP_SERVER when it dispatches; fall back to ../mcp/index.ts.
mcp_server_path() {
  if [[ -n "${ENG_MCP_SERVER:-}" ]]; then
    echo "$ENG_MCP_SERVER"
  else
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
    echo "$here/mcp/index.ts"
  fi
}

# Agent registry. Each detector echoes "name|kind|configpath" if present.
#   kind: cli  -> register via a CLI command
#         json -> merge into a JSON config file
# configpath is empty for cli agents.
detect_agents() {
  local home="${HOME:-}"
  command -v claude >/dev/null 2>&1 && echo "claude-code|cli|"
  [[ -f "$home/.cursor/mcp.json" ]]                 && echo "cursor|json|$home/.cursor/mcp.json"
  [[ -f "$home/.config/Code/User/mcp.json" ]]       && echo "vscode|json|$home/.config/Code/User/mcp.json"
  [[ -f "$home/.gemini/settings.json" ]]            && echo "gemini|json|$home/.gemini/settings.json"
  [[ -f "$home/.codex/config.json" ]]               && echo "codex|json|$home/.codex/config.json"
  [[ -f "$home/.codeium/windsurf/mcp_config.json" ]] && echo "windsurf|json|$home/.codeium/windsurf/mcp_config.json"
  [[ -f "$home/.config/opencode/opencode.json" ]]   && echo "opencode|json|$home/.config/opencode/opencode.json"
  return 0
}

# merge_json_config <config_path> <server_path>
#   Backs up the file, then idempotently adds an `engleader` MCP entry under
#   the standard `.mcpServers` key. Uses bun to run the server.
merge_json_config() {
  local cfg="$1" server="$2"
  local ts; ts="$(date -u +%Y%m%d%H%M%S)"
  cp "$cfg" "${cfg}.bak-${ts}" || {
    echo "Error: could not back up $cfg; aborting merge." >&2
    return 1
  }

  # Treat an empty file as an empty object.
  local current; current="$(cat "$cfg")"
  [[ -z "${current// }" ]] && current="{}"

  echo "$current" | jq \
    --arg path "$server" \
    '.mcpServers.engleader = { command: "bun", args: ["run", $path] }' \
    > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}

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
    local entry=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "${line%%|*}" == "$target_agent" ]]; then entry="$line"; break; fi
    done <<<"$detected"
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

if [[ -z "${ENG_MCP_LIB:-}" ]]; then
  main "$@"
fi
