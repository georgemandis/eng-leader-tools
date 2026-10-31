#!/usr/bin/env bash
# Plain-shell tests for quick-reviews.sh. Run: bash src/quick-reviews.test.sh
#
# Stubs `gh` with a fixture so the filters can be checked without network.
# Covers the default (unapproved, 1-2 files) mode and the -A
# (approved-but-unmerged, any size) mode.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok() { if eval "$2"; then echo "ok - $1"; PASS=$((PASS+1)); else echo "FAIL - $1"; FAIL=$((FAIL+1)); fi; }

STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT

# Fixture: dates are relative to now so the age column is predictable.
jq -n '
  def ago(d): (now - d*86400) | todate;
  [
    {number:1, title:"approved small old",  url:"u1", author:{login:"a"}, changedFiles:1,  updatedAt:ago(10), reviewDecision:"APPROVED",          isDraft:false},
    {number:2, title:"approved big recent", url:"u2", author:{login:"b"}, changedFiles:20, updatedAt:ago(2),  reviewDecision:"APPROVED",          isDraft:false},
    {number:3, title:"approved draft",      url:"u3", author:{login:"c"}, changedFiles:1,  updatedAt:ago(5),  reviewDecision:"APPROVED",          isDraft:true},
    {number:4, title:"unapproved small",    url:"u4", author:{login:"d"}, changedFiles:2,  updatedAt:ago(1),  reviewDecision:"REVIEW_REQUIRED",   isDraft:false},
    {number:5, title:"unapproved big",      url:"u5", author:{login:"e"}, changedFiles:9,  updatedAt:ago(3),  reviewDecision:"CHANGES_REQUESTED", isDraft:false}
  ]' > "$STUB/prs.json"

cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
cat "$(dirname "$0")/prs.json"
GH
chmod +x "$STUB/gh"

run() { PATH="$STUB:$PATH" ENG_TEAM_MEMBERS= "$SCRIPT_DIR/quick-reviews.sh" -o org -r repo "$@"; }

# --- default mode: unchanged behaviour ---
out="$(run 2>/dev/null)"
ok "default lists the unapproved 1-2 file PR" '[[ "$out" == *"unapproved small"* ]]'
ok "default hides approved PRs" '[[ "$out" != *"approved"*"old"* ]]'
ok "default hides PRs with >2 files" '[[ "$out" != *"unapproved big"* ]]'

out="$(run --csv 2>/dev/null)"
ok "default --csv has the original header" '[[ "$(printf "%s\n" "$out" | head -1)" == "Date,Title,Author,Files,URL" ]]'
ok "default --csv carries the unapproved small PR" '[[ "$out" == *",\"unapproved small\",d,2,u4"* ]]'

# --- -A mode: approved but not merged, any size ---
out="$(run -A 2>/dev/null)"
ok "-A lists the approved small PR" '[[ "$out" == *"approved small old"* ]]'
ok "-A lists the approved 20-file PR (no size filter)" '[[ "$out" == *"approved big recent"* ]]'
ok "-A hides drafts" '[[ "$out" != *"approved draft"* ]]'
ok "-A hides unapproved PRs" '[[ "$out" != *"unapproved"* ]]'
ok "-A sorts oldest activity first" \
  '[[ "$(printf "%s\n" "$out" | grep -n "approved small old" | cut -d: -f1)" -lt "$(printf "%s\n" "$out" | grep -n "approved big recent" | cut -d: -f1)" ]]'
ok "-A shows age in days on the old PR" '[[ "$out" == *"10d"*"approved small old"* ]]'

# --- -A --csv ---
out="$(run -A --csv 2>/dev/null)"
ok "-A --csv header has Age and Files" '[[ "$(printf "%s\n" "$out" | head -1)" == "Date,Age,Title,Author,Files,URL" ]]'
ok "-A --csv row carries the 20-file PR with age 2" '[[ "$out" == *",2,\"approved big recent\",b,20,u2"* ]]'

# --- empty state ---
jq '[.[] | select(.reviewDecision != "APPROVED")]' "$STUB/prs.json" > "$STUB/none.json" && cp "$STUB/none.json" "$STUB/prs.json"
out="$(run -A 2>/dev/null)"
ok "-A with no approved PRs prints a specific message" '[[ "$out" == *"No approved, unmerged PRs"* ]]'

# --- flag conflict ---
ok "-A with -a exits non-zero" '! run -A -a >/dev/null 2>&1'
ok "-A with -a explains the conflict on stderr" '[[ "$(run -A -a 2>&1 >/dev/null)" == *"-A"*"-a"* ]]'

echo; echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
