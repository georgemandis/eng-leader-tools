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

# main() runs only when invoked directly, not when sourced for tests.
main() {
  echo "eng mcp install — coming together across tasks 6-9" >&2
}

if [[ -z "${ENG_MCP_LIB:-}" ]]; then
  main "$@"
fi
