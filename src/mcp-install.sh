#!/usr/bin/env bash
#
# mcp-install.sh — install the engleader MCP server into AI agents.
# Dispatched as `eng mcp`. Detects installed agents, prompts, registers.
#
# Note: intentionally NOT using -e. Detection and registration rely on
# `cmd && echo ok || echo fail` and `test && echo ...` short-circuits that
# would abort the script under `set -e`.
set -uo pipefail

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

# merge_json_config <config_path> <eng-mcp-binary>
#   Backs up the file, then idempotently adds an `engleader` MCP entry under
#   the standard `.mcpServers` key, pointing at the compiled eng-mcp binary.
merge_json_config() {
  local cfg="$1" bin="$2"
  local ts; ts="$(date -u +%Y%m%d%H%M%S)"
  cp "$cfg" "${cfg}.bak-${ts}" || {
    echo "Error: could not back up $cfg; aborting merge." >&2
    return 1
  }

  # Treat an empty file as an empty object.
  local current; current="$(cat "$cfg")"
  [[ -z "${current// }" ]] && current="{}"

  echo "$current" | jq \
    --arg bin "$bin" \
    '.mcpServers.engleader = { command: $bin, args: [] }' \
    > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}

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

# Print the planned action for each detected agent and prompt for selection.
main() {
  local bin; bin="$(mcp_bin_path)"

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
    register_agent "$entry" "$bin"
    return 0
  fi
  if [[ -n "$install_all" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      register_agent "$entry" "$bin"
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
        register_agent "$entry" "$bin"
      done <<<"$detected" ;;
    c|C)
      # Feed the loop on FD 3 so stdin stays the terminal for `read -r yn`
      # (otherwise read yn consumes the next agent line from the here-string).
      while IFS='|' read -r name kind path <&3; do
        [[ -z "$name" ]] && continue
        printf "Install into %s? [y/N]: " "$name"
        read -r yn
        [[ "$yn" == "y" || "$yn" == "Y" ]] && register_agent "$name|$kind|$path" "$bin"
      done 3<<<"$detected" ;;
    *)
      echo "Aborted." ;;
  esac
}

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
      # Feed the loop on FD 3 so stdin stays the terminal for `read -r yn`
      # (otherwise read yn consumes the next agent line from the here-string).
      while IFS='|' read -r name kind path <&3; do
        [[ -z "$name" ]] && continue
        printf "Remove from %s? [y/N]: " "$name"
        read -r yn
        [[ "$yn" == "y" || "$yn" == "Y" ]] && unregister_agent "$name|$kind|$path"
      done 3<<<"$registered" ;;
    *)
      echo "Aborted." ;;
  esac
}

if [[ -z "${ENG_MCP_LIB:-}" ]]; then
  if [[ "${1:-}" == "uninstall" ]]; then
    shift; uninstall_main "$@"
  else
    [[ "${1:-}" == "install" ]] && shift
    main "$@"
  fi
fi
