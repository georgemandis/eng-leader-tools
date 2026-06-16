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

echo "----"; echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
