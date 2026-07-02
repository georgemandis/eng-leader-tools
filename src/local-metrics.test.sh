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

# A real git repo for the arg-validation cases below (these must reach the
# validation code, not fail on require_git_repo first).
REPO="$(mktemp -d)"
(
  cd "$REPO" && git init -q && git config user.email t@t.co && git config user.name t
  echo hi > a.txt && git add -A && git commit -qm init
)

# A value-taking flag given as the FINAL token (no value) must fail with a
# clear message and exit 1 — not a silent exit from shift-past-end under set -e.
run_last_flag() { # <script> <flag>
  (cd "$REPO" && "$SCRIPT_DIR/$1.sh" "$2" 2>&1 >/dev/null); # capture stderr
}
ok "hotspots --high-lines (no value) errors, not silent" \
  '[[ -n "$(run_last_flag hotspots --high-lines)" ]]'
ok "hotspots --med-lines (no value) errors, not silent" \
  '[[ -n "$(run_last_flag hotspots --med-lines)" ]]'
ok "test-ratio --healthy (no value) errors, not silent" \
  '[[ -n "$(run_last_flag test-ratio --healthy)" ]]'
ok "test-ratio --low (no value) errors, not silent" \
  '[[ -n "$(run_last_flag test-ratio --low)" ]]'
ok "hotspots --high-lines (no value) exits non-zero" \
  '! (cd "$REPO" && "$SCRIPT_DIR/hotspots.sh" --high-lines >/dev/null 2>&1)'

# A non-numeric `days` positional in --json mode must yield a BAD_ARGS
# envelope, not a raw jq/date error.
out="$(cd "$REPO" && "$SCRIPT_DIR/hotspots.sh" abc --json 2>/dev/null)"
ok "hotspots abc --json emits parseable JSON" \
  'printf "%s" "$out" | jq -e . >/dev/null 2>&1'
ok "hotspots abc --json uses code BAD_ARGS" \
  '[[ "$(printf "%s" "$out" | jq -r ".code" 2>/dev/null)" == "BAD_ARGS" ]]'

# A tracked file whose name contains consecutive spaces must still appear in
# hotspots output (the churn→ls-files join must not mangle whitespace).
WSREPO="$(mktemp -d)"
(
  cd "$WSREPO" && git init -q && git config user.email t@t.co && git config user.name t
  mkdir -p dir
  printf 'a\nb\n' > "dir/two  spaces.txt"      # two spaces
  for i in 1 2 3; do echo "c$i" >> "dir/two  spaces.txt"; git add -A; git commit -qm "c$i"; done
)
wsout="$(cd "$WSREPO" && "$SCRIPT_DIR/hotspots.sh" 90 1 --json 2>/dev/null)"
ok "hotspots keeps a file with consecutive spaces in its name" \
  'printf "%s" "$wsout" | jq -e ".data.files[].path | select(. == \"dir/two  spaces.txt\")" >/dev/null 2>&1'

# todo-debt shares the same churn/aggregation shape — its per-file path must
# also preserve consecutive spaces.
(cd "$WSREPO" && printf 'x=1  # TODO fix\n' > "dir/two  spaces.txt" && git add -A && git commit -qm todo)
tdout="$(cd "$WSREPO" && "$SCRIPT_DIR/todo-debt.sh" --json 2>/dev/null)"
ok "todo-debt keeps a file with consecutive spaces in its name" \
  'printf "%s" "$tdout" | jq -e ".data.files[].path | select(. == \"dir/two  spaces.txt\")" >/dev/null 2>&1'

rm -rf "$REPO" "$WSREPO"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
