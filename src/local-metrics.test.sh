#!/usr/bin/env bash
# Plain-shell test runner for the local working-tree metrics
# (hotspots, todo-debt, test-ratio). Run: bash src/local-metrics.test.sh
#
# Focuses on the JSON contract: in --json mode every failure path must emit a
# valid JSON error envelope on STDOUT (so the MCP runner can parse it), not a
# plain-text message on STDERR with empty stdout.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok() { if eval "$2"; then echo "ok - $1"; PASS=$((PASS+1)); else echo "FAIL - $1"; FAIL=$((FAIL+1)); fi; }

# A directory that is NOT inside any git work tree.
NONREPO="$(mktemp -d)"
trap 'rm -rf "$NONREPO"' EXIT

# In --json mode, running outside a git repo must print a NOT_FOUND error
# envelope on stdout (parseable JSON with a `code`), not empty stdout.
for script in hotspots todo-debt test-ratio; do
  out="$(cd "$NONREPO" && "$SCRIPT_DIR/$script.sh" --json 2>/dev/null)"
  ok "$script --json outside a repo emits JSON on stdout" \
    'printf "%s" "$out" | jq -e . >/dev/null 2>&1'
  ok "$script --json outside a repo uses code NOT_FOUND" \
    '[[ "$(printf "%s" "$out" | jq -r ".code" 2>/dev/null)" == "NOT_FOUND" ]]'
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
