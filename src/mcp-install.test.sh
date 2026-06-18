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

# --- main() --agent selection (both forms), dry-run so nothing mutates ---
MTMP="$(mktemp -d)"
mkdir -p "$MTMP/.cursor"; echo '{}' > "$MTMP/.cursor/mcp.json"
mfb="$MTMP/bin"; mkdir -p "$mfb"; printf '#!/bin/sh\ntrue\n' > "$mfb/claude"; chmod +x "$mfb/claude"

OUT_EQ="$(HOME="$MTMP" PATH="$mfb:$PATH" ENG_MCP_SERVER=/x/index.ts main --agent=cursor --dry-run 2>&1)"
ok "main --agent=cursor selects cursor (dry-run)" '[[ "$OUT_EQ" == *"[dry-run] cursor"* ]]'

OUT_SP="$(HOME="$MTMP" PATH="$mfb:$PATH" ENG_MCP_SERVER=/x/index.ts main --agent cursor --dry-run 2>&1)"
ok "main --agent cursor (space form) selects cursor (dry-run)" '[[ "$OUT_SP" == *"[dry-run] cursor"* ]]'

OUT_BOGUS="$(HOME="$MTMP" PATH="$mfb:$PATH" ENG_MCP_SERVER=/x/index.ts main --agent bogus --dry-run 2>&1)"; rc=$?
ok "main --agent bogus errors" '[[ "$rc" -ne 0 && "$OUT_BOGUS" == *"not detected"* ]]'

ok "main --agent=cursor leaves config unmutated in dry-run" '! grep -q engleader "$MTMP/.cursor/mcp.json"'
rm -rf "$MTMP"

# --- register_agent unknown kind ---
OUT_UNK="$(register_agent "foo|bogus|" "/x/index.ts" 2>&1)"
ok "unknown kind is skipped with an error" '[[ "$OUT_UNK" == *"unknown registration kind"* ]]'

# --- agent_has_engleader probe ---
HTMP="$(mktemp -d)"
has_cfg="$HTMP/has.json";  echo '{"mcpServers":{"engleader":{"command":"bun"}}}' > "$has_cfg"
no_cfg="$HTMP/no.json";    echo '{"mcpServers":{"other":{"command":"x"}}}'        > "$no_cfg"

ok "agent_has_engleader true when engleader present" 'agent_has_engleader "cursor|json|$has_cfg"'
ok "agent_has_engleader false when engleader absent" '! agent_has_engleader "cursor|json|$no_cfg"'
ok "agent_has_engleader false when file missing" '! agent_has_engleader "cursor|json|$HTMP/nope.json"'
rm -rf "$HTMP"

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

# --- interactive 'choose' prompts EVERY agent (regression: read yn must not
#     steal the loop's here-string stdin, which made it exit after agent #1) ---
CTMP="$(mktemp -d)"
# fake claude (registered) + two json agents -> deterministic 3-agent list.
cfb="$CTMP/bin"; mkdir -p "$cfb"
cat > "$cfb/claude" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "mcp get") exit 0 ;;     # engleader is registered (for uninstall detection)
  *) exit 0 ;;
esac
EOF
chmod +x "$cfb/claude"
mkdir -p "$CTMP/.cursor";          echo '{"mcpServers":{"engleader":{"command":"bun"}}}' > "$CTMP/.cursor/mcp.json"
mkdir -p "$CTMP/.config/opencode"; echo '{"mcpServers":{"engleader":{"command":"bun"}}}' > "$CTMP/.config/opencode/opencode.json"

# install: choose, answer y to ALL three agents. Dry-run so nothing mutates.
OUT_CHOOSE_INST="$(printf 'c\ny\ny\ny\n' | HOME="$CTMP" PATH="$cfb:$PATH" ENG_MCP_SERVER=/x/index.ts bash "$SCRIPT_DIR/mcp-install.sh" install --dry-run 2>&1)"
ok "install choose prompts claude-code (agent #1)" '[[ "$OUT_CHOOSE_INST" == *"Install into claude-code"* ]]'
ok "install choose prompts cursor (agent #2 not eaten)" '[[ "$OUT_CHOOSE_INST" == *"Install into cursor"* ]]'
ok "install choose prompts opencode (agent #3 not eaten)" '[[ "$OUT_CHOOSE_INST" == *"Install into opencode"* ]]'
ok "install choose dry-runs ALL agents" '[[ "$OUT_CHOOSE_INST" == *"[dry-run] claude-code"* && "$OUT_CHOOSE_INST" == *"[dry-run] cursor"* && "$OUT_CHOOSE_INST" == *"[dry-run] opencode"* ]]'

# uninstall: choose, answer y to ALL three (all have engleader registered).
OUT_CHOOSE_UNINST="$(printf 'c\ny\ny\ny\n' | HOME="$CTMP" PATH="$cfb:$PATH" ENG_MCP_SERVER=/x/index.ts bash "$SCRIPT_DIR/mcp-install.sh" uninstall --dry-run 2>&1)"
ok "uninstall choose prompts claude-code (agent #1)" '[[ "$OUT_CHOOSE_UNINST" == *"Remove from claude-code"* ]]'
ok "uninstall choose prompts cursor (agent #2 not eaten)" '[[ "$OUT_CHOOSE_UNINST" == *"Remove from cursor"* ]]'
ok "uninstall choose prompts opencode (agent #3 not eaten)" '[[ "$OUT_CHOOSE_UNINST" == *"Remove from opencode"* ]]'
ok "uninstall choose dry-runs ALL agents" '[[ "$OUT_CHOOSE_UNINST" == *"[dry-run] claude-code"* && "$OUT_CHOOSE_UNINST" == *"[dry-run] cursor"* && "$OUT_CHOOSE_UNINST" == *"[dry-run] opencode"* ]]'
rm -rf "$CTMP"

echo "----"; echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
