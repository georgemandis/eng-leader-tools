# codeshape Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `codeshape`, a standalone local-first CLI + MCP server that scores the current health of a codebase (CodeScene-style deduction score over pluggable analyzer adapters, self-derived git churn, three-KPI project rollup).

**Architecture:** A bash CLI (`codeshape`) orchestrates four bounded units: (1) analyzer **adapters** that probe `PATH` and normalize per-file metrics to a common record; (2) a pure **scorer** that turns a normalized record + config into a 1–10 score; (3) a **churn** step deriving change counts from `git log`; (4) an **aggregator** producing three project KPIs + coverage. A Bun/TypeScript MCP server exposes one tool, `codeshape_health`. All conventions (JSON `{error,code}` envelopes, `ToolDef` shape, script structure) mirror the engleader.tools repo but with zero runtime coupling.

**Tech Stack:** Bash (CLI + adapters, `set -euo pipefail`), `jq` (JSON), `git` (churn), external analyzers (`scc`, `lizard`, `radon`, `gocyclo`) probed at runtime, Bun + TypeScript + `@modelcontextprotocol/sdk` + `zod` (MCP server). Tests: plain-shell runner (`bats`-free, mirroring `local-metrics.test.sh`) for bash, `bun:test` for MCP.

## Global Constraints

- Tool binary name: `codeshape`. MCP tool name: `codeshape_health`. MCP server prefix: `codeshape`.
- Scripts: `#!/usr/bin/env bash` + `set -euo pipefail`. Value-taking flags MUST use a `need_value` guard (never shift past end under `set -e`).
- JSON mode: every failure path emits a valid `{error, code}` envelope on **stdout** (never plain-text-on-stderr-only). Codes: `NOT_FOUND`, `BAD_ARGS`, `DEP_MISSING`.
- Envelope shape (success): `{ metric, repo, window_days, generated_at, data }`. `metric` is always `"codeshape"`. No `team` field (this tool is not team-aware).
- Score domain: `[1.0, 10.0]`, one decimal place. Tiers: `green ≥ 8.0`, `yellow ≥ 5.0`, else `red` (config-overridable).
- Files whose language no adapter claims are **skipped**, never heuristically scored; they are counted under `coverage`.
- If **no** adapter binary is installed at all → `DEP_MISSING` (fail loudly).
- Default thresholds: ccn `> 10`, function length `> 60` lines, args `> 4`, nesting `> 3`. Weights and thresholds live in a config file.
- Normalized per-file record (JSON): `{ "path": str, "lang": str, "loc": int, "fns": [{ "name": str, "ccn": int, "len": int, "args": int, "nesting": int }], "dup_ratio": float }`.
- Function→file rollup: **worst-offending function** (file's `ccn` = max over its functions' `ccn`, etc.).
- Reference implementations to mirror (read-only, in the engleader repo): `src/hotspots.sh`, `src/_common.sh`, `src/local-metrics.test.sh`, `mcp/tools.ts`, `mcp/tools.test.ts`.

---

### Task 1: Project scaffold + shared envelope helpers

**Files:**
- Create: `codeshape/lib/_common.sh`
- Create: `codeshape/test/common.test.sh`
- Create: `codeshape/README.md`

**Interfaces:**
- Produces: `emit_json <metric> <window_days|null> <data_json>`, `json_error <code> <message>` (exits 1), `json_preflight_local` (requires `jq` + `git`), `require_git_repo` (sets `ROOT`; in JSON mode emits `NOT_FOUND` envelope and exits), `resolve_local_repo` (sets `REPO` best-effort from origin remote or dir name). These mirror `engleader/src/_common.sh` but drop the `team` field from the envelope.

- [ ] **Step 1: Write the failing test**

```bash
# codeshape/test/common.test.sh
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok() { if eval "$2"; then echo "ok - $1"; PASS=$((PASS+1)); else echo "FAIL - $1"; FAIL=$((FAIL+1)); fi; }

# emit_json builds an envelope with metric/repo/window_days/generated_at/data and NO team field.
out="$(bash -c 'source "'"$DIR"'/lib/_common.sh"; REPO=acme/widget; emit_json codeshape 90 "{\"x\":1}"')"
ok "emit_json is valid JSON"            'printf "%s" "$out" | jq -e . >/dev/null 2>&1'
ok "emit_json metric is codeshape"      '[[ "$(printf "%s" "$out" | jq -r .metric)" == "codeshape" ]]'
ok "emit_json carries data through"     '[[ "$(printf "%s" "$out" | jq -r .data.x)" == "1" ]]'
ok "emit_json window_days is numeric"   '[[ "$(printf "%s" "$out" | jq -r .window_days)" == "90" ]]'
ok "emit_json has NO team field"        '[[ "$(printf "%s" "$out" | jq -r "has(\"team\")")" == "false" ]]'

# json_error prints {error,code} and exits non-zero.
err="$(bash -c 'source "'"$DIR"'/lib/_common.sh"; json_error BAD_ARGS "bad"' 2>/dev/null)"
ok "json_error code is BAD_ARGS"        '[[ "$(printf "%s" "$err" | jq -r .code)" == "BAD_ARGS" ]]'
ok "json_error exits non-zero"          '! bash -c '"'"'source "'"$DIR"'/lib/_common.sh"; json_error X y'"'"' >/dev/null 2>&1'

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash codeshape/test/common.test.sh`
Expected: FAIL — `lib/_common.sh` does not exist (source errors).

- [ ] **Step 3: Write minimal implementation**

Create `codeshape/lib/_common.sh` by copying the `emit_json`, `json_error`, `json_preflight_local`, `require_git_repo`, and `resolve_local_repo` functions from `engleader/src/_common.sh`, with ONE change: remove the `team` argument and the `team` key from `emit_json`'s `jq` object. Final `emit_json`:

```bash
#!/usr/bin/env bash
# Shared helpers for codeshape scripts (envelope + local-repo resolution).

emit_json() {
  local metric="$1" window="$2" data="$3"
  local generated
  generated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -n \
    --arg metric "$metric" \
    --arg repo "${REPO:-}" \
    --arg generated "$generated" \
    --argjson window "$window" \
    --argjson data "$data" \
    '{ metric: $metric, repo: $repo, window_days: $window,
       generated_at: $generated, data: $data }'
}

json_error() {
  local code="$1" message="$2"
  jq -n --arg code "$code" --arg message "$message" '{ error: $message, code: $code }'
  exit 1
}

json_preflight_local() {
  command -v jq  >/dev/null 2>&1 || json_error DEP_MISSING "jq is not installed"
  command -v git >/dev/null 2>&1 || json_error DEP_MISSING "git is not installed"
}

require_git_repo() {
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) && return 0
  [[ "${JSON:-false}" == "true" ]] && \
    json_error NOT_FOUND "not inside a git repository (codeshape analyzes the local working tree)"
  echo "Error: not inside a git repository" >&2
  return 1
}

resolve_local_repo() {
  local url
  url=$(git remote get-url origin 2>/dev/null || true); url="${url%.git}"
  if [[ "$url" =~ github\.com[:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$ ]]; then
    REPO="${BASH_REMATCH[1]}"
  elif [[ -n "${ROOT:-}" ]]; then REPO="$(basename "$ROOT")"; else REPO=""; fi
}
```

Create a minimal `codeshape/README.md` with a one-paragraph description (from the spec's Concept section) and a "Requirements: git, jq, and at least one of: scc, lizard, radon, gocyclo" line.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash codeshape/test/common.test.sh`
Expected: PASS — `PASS=8 FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add codeshape/lib/_common.sh codeshape/test/common.test.sh codeshape/README.md
git commit -m "feat(codeshape): scaffold + envelope helpers"
```

---

### Task 2: Default config + config loader

**Files:**
- Create: `codeshape/config.default`
- Create: `codeshape/lib/config.sh`
- Create: `codeshape/test/config.test.sh`

**Interfaces:**
- Consumes: none.
- Produces: `load_config` — sources `config.default`, then overlays `.codeshaperc` from the analyzed repo root if present. Sets these globals: `T_CCN`, `T_LEN`, `T_ARGS`, `T_NEST` (thresholds), `W_CCN`, `W_LEN`, `W_ARGS`, `W_NEST`, `W_DUP` (weights), `TIER_GREEN`, `TIER_YELLOW` (score cutoffs), `CHURN_FLOOR` (min change count for a hotspot).

- [ ] **Step 1: Write the failing test**

```bash
# codeshape/test/config.test.sh
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok() { if eval "$2"; then echo "ok - $1"; PASS=$((PASS+1)); else echo "FAIL - $1"; FAIL=$((FAIL+1)); fi; }

# Defaults load from config.default when no override is present.
eval "$(bash -c 'source "'"$DIR"'/lib/config.sh"; ROOT=/nonexistent load_config; \
  echo T_CCN=$T_CCN; echo T_LEN=$T_LEN; echo TIER_GREEN=$TIER_GREEN; echo CHURN_FLOOR=$CHURN_FLOOR')"
ok "default T_CCN is 10"      '[[ "$T_CCN" == "10" ]]'
ok "default T_LEN is 60"      '[[ "$T_LEN" == "60" ]]'
ok "default TIER_GREEN is 8"  '[[ "$TIER_GREEN" == "8" ]]'
ok "default CHURN_FLOOR is 3" '[[ "$CHURN_FLOOR" == "3" ]]'

# A repo-root .codeshaperc overrides a default.
OV="$(mktemp -d)"; echo 'T_CCN=25' > "$OV/.codeshaperc"
eval "$(bash -c 'source "'"$DIR"'/lib/config.sh"; ROOT="'"$OV"'" load_config; echo T_CCN=$T_CCN')"
ok ".codeshaperc overrides T_CCN" '[[ "$T_CCN" == "25" ]]'
rm -rf "$OV"

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash codeshape/test/config.test.sh`
Expected: FAIL — `lib/config.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

```bash
# codeshape/config.default  (sourced bash — plain KEY=value)
# Thresholds (a metric is penalized only ABOVE these).
T_CCN=10
T_LEN=60
T_ARGS=4
T_NEST=3
# Penalty weights (points deducted per unit of overage; dup is per ratio-point).
W_CCN=0.30
W_LEN=0.03
W_ARGS=0.50
W_NEST=1.00
W_DUP=5.00
# Score→tier cutoffs.
TIER_GREEN=8
TIER_YELLOW=5
# Minimum change count for a file to count toward Hotspot Health.
CHURN_FLOOR=3
```

```bash
# codeshape/lib/config.sh
load_config() {
  local self_dir; self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck disable=SC1091
  source "$self_dir/config.default"
  local override="${ROOT:-}/.codeshaperc"
  # Only source the override if it exists AND contains just KEY=value lines
  # (defense against executing arbitrary code from an analyzed repo).
  if [[ -f "$override" ]] && ! grep -qvE '^\s*(#.*)?$|^[A-Z_]+=[0-9.]+\s*$' "$override"; then
    :  # malformed line found → ignore override entirely
  elif [[ -f "$override" ]]; then
    # shellcheck disable=SC1090
    source "$override"
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash codeshape/test/config.test.sh`
Expected: PASS — `PASS=5 FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add codeshape/config.default codeshape/lib/config.sh codeshape/test/config.test.sh
git commit -m "feat(codeshape): default config + safe config loader"
```

---

### Task 3: Pure scorer

**Files:**
- Create: `codeshape/lib/scorer.sh`
- Create: `codeshape/test/scorer.test.sh`

**Interfaces:**
- Consumes: config globals from Task 2 (`T_*`, `W_*`).
- Produces: `score_record <ccn> <len> <args> <nesting> <dup_ratio>` — echoes a score in `[1.0, 10.0]` to one decimal. Pure: reads only its args + `T_*`/`W_*` globals, no I/O. Formula: `10 − W_CCN·over(ccn,T_CCN) − W_LEN·over(len,T_LEN) − W_ARGS·over(args,T_ARGS) − W_NEST·over(nesting,T_NEST) − W_DUP·dup_ratio`, clamped to `[1,10]`, where `over(x,T)=max(0,x−T)`.

- [ ] **Step 1: Write the failing test**

```bash
# codeshape/test/scorer.test.sh
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok() { if eval "$2"; then echo "ok - $1"; PASS=$((PASS+1)); else echo "FAIL - $1"; FAIL=$((FAIL+1)); fi; }
sc() { bash -c 'source "'"$DIR"'/config.default"; source "'"$DIR"'/lib/scorer.sh"; score_record "$@"' _ "$@"; }

# Clean file (all under threshold, no dup) → perfect 10.0
ok "clean file scores 10.0"        '[[ "$(sc 5 30 2 1 0)" == "10.0" ]]'
# ccn 20 → over=10, penalty 0.30*10=3.0 → 7.0
ok "high ccn deducts correctly"    '[[ "$(sc 20 30 2 1 0)" == "7.0" ]]'
# nesting 6 → over=3, penalty 1.00*3=3.0 → 7.0
ok "deep nesting deducts"          '[[ "$(sc 5 30 2 6 0)" == "7.0" ]]'
# Everything terrible → clamps at floor 1.0, never below
ok "catastrophic file clamps to 1.0" '[[ "$(sc 200 2000 20 40 1) " == "1.0 " ]]'
# dup_ratio 0.4 → penalty 5.0*0.4=2.0 → 8.0
ok "duplication deducts"           '[[ "$(sc 5 30 2 1 0.4)" == "8.0" ]]'

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash codeshape/test/scorer.test.sh`
Expected: FAIL — `lib/scorer.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

```bash
# codeshape/lib/scorer.sh
# score_record <ccn> <len> <args> <nesting> <dup_ratio>  → score in [1.0,10.0]
score_record() {
  awk -v ccn="$1" -v len="$2" -v args="$3" -v nest="$4" -v dup="$5" \
      -v tccn="$T_CCN" -v tlen="$T_LEN" -v targs="$T_ARGS" -v tnest="$T_NEST" \
      -v wccn="$W_CCN" -v wlen="$W_LEN" -v wargs="$W_ARGS" -v wnest="$W_NEST" -v wdup="$W_DUP" '
    function over(x, t) { return (x > t) ? (x - t) : 0 }
    BEGIN {
      s = 10 - wccn*over(ccn,tccn) - wlen*over(len,tlen) \
             - wargs*over(args,targs) - wnest*over(nest,tnest) - wdup*dup
      if (s < 1) s = 1; if (s > 10) s = 10
      printf "%.1f", s
    }'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash codeshape/test/scorer.test.sh`
Expected: PASS — `PASS=5 FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add codeshape/lib/scorer.sh codeshape/test/scorer.test.sh
git commit -m "feat(codeshape): pure deduction scorer"
```

---

### Task 4: Adapter layer (scc + heuristic-free skip)

**Files:**
- Create: `codeshape/lib/adapters.sh`
- Create: `codeshape/test/adapters.test.sh`

**Interfaces:**
- Consumes: none.
- Produces:
  - `adapter_available` — echoes the names of installed analyzers (subset of `scc lizard radon gocyclo`), one per line; empty if none.
  - `analyze_file <abs_path> <rel_path>` — echoes ONE normalized JSON record (the record shape from Global Constraints) using the best available adapter for that file's language, or exits non-zero (prints nothing) if no adapter claims the language. Rollup to file level uses worst-offending function.

**Note on adapter scope:** This task implements the **scc** adapter (single Go binary, ~250 languages, gives per-file LoC + complexity) and the selection/skip harness. `lizard`/`radon`/`gocyclo` adapters are added in Task 5 behind the same interface. scc reports file-level complexity (not per-function), so its record has a single synthetic `fns` entry: `[{name:"<file>", ccn:<complexity>, len:<loc>, args:0, nesting:0}]` and `dup_ratio:0`. This is a documented limitation, richer adapters improve on it.

- [ ] **Step 1: Write the failing test**

```bash
# codeshape/test/adapters.test.sh
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()   { if eval "$2"; then echo "ok - $1"; PASS=$((PASS+1)); else echo "FAIL - $1"; FAIL=$((FAIL+1)); fi; }
skip() { echo "skip - $1"; }

source "$DIR/lib/adapters.sh"

if command -v scc >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  printf 'package main\nfunc main(){ if true { for i:=0;i<3;i++{} } }\n' > "$TMP/main.go"
  rec="$(analyze_file "$TMP/main.go" "main.go")"
  ok "scc adapter emits valid JSON"        'printf "%s" "$rec" | jq -e . >/dev/null 2>&1'
  ok "record path is the rel path"         '[[ "$(printf "%s" "$rec" | jq -r .path)" == "main.go" ]]'
  ok "record has an loc integer"           'printf "%s" "$rec" | jq -e ".loc | type == \"number\"" >/dev/null'
  ok "record fns is a non-empty array"     'printf "%s" "$rec" | jq -e ".fns | length >= 1" >/dev/null'
  # A language no adapter claims (e.g. a plain .md) → non-zero exit, no output.
  echo "# hi" > "$TMP/readme.md"
  ok "unclaimed language is skipped (nonzero exit)" '! analyze_file "'"$TMP"'/readme.md" "readme.md" >/dev/null 2>&1'
  rm -rf "$TMP"
else
  skip "scc not installed — adapter behavior tests skipped"
fi
ok "adapter_available lists something or is empty" 'adapter_available >/dev/null 2>&1 || true; true'

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash codeshape/test/adapters.test.sh`
Expected: FAIL — `lib/adapters.sh` does not exist. (If `scc` is absent the file-behavior asserts are skipped, but the source line still fails until the file exists.)

- [ ] **Step 3: Write minimal implementation**

```bash
# codeshape/lib/adapters.sh
# Normalized record shape:
#   { path, lang, loc, fns:[{name,ccn,len,args,nesting}], dup_ratio }

adapter_available() {
  local a
  for a in scc lizard radon gocyclo; do command -v "$a" >/dev/null 2>&1 && echo "$a"; done
}

# analyze_file <abs_path> <rel_path> → one JSON record, or nonzero exit if unclaimed.
analyze_file() {
  local abs="$1" rel="$2"
  # Try scc first (broadest language coverage). scc emits per-file JSON with
  # Language, Lines, Complexity when given a single file via --by-file --format json.
  if command -v scc >/dev/null 2>&1; then
    local out
    out="$(scc --by-file --format json "$abs" 2>/dev/null)" || out=""
    # scc groups by language; find the single file entry.
    local rec
    rec="$(printf '%s' "$out" | jq -c --arg p "$rel" '
      [ .[] as $lang | $lang.Files[] | {lang:$lang.Name, loc:.Lines, ccn:.Complexity} ]
      | .[0] // empty
      | select(. != null)
      | { path:$p, lang:.lang, loc:.loc,
          fns:[ {name:"<file>", ccn:.ccn, len:.loc, args:0, nesting:0} ],
          dup_ratio:0 }' 2>/dev/null)"
    if [[ -n "$rec" && "$rec" != "null" ]]; then printf '%s\n' "$rec"; return 0; fi
  fi
  return 1  # no adapter claimed this file
}
```

*(Implementer note: verify scc's exact JSON field names with `scc --by-file --format json <file>` on your machine; adjust the `jq` field paths — `Files[]`, `Lines`, `Complexity`, `Name` — to match the installed scc version. The test asserts the record SHAPE, not scc internals.)*

- [ ] **Step 4: Run test to verify it passes**

Run: `bash codeshape/test/adapters.test.sh`
Expected: PASS (asserts run if `scc` present; otherwise the file-behavior block prints `skip -` lines and the run still ends `FAIL=0`).

- [ ] **Step 5: Commit**

```bash
git add codeshape/lib/adapters.sh codeshape/test/adapters.test.sh
git commit -m "feat(codeshape): adapter layer with scc + skip-on-unclaimed"
```

---

### Task 5: lizard adapter (per-function enrichment)

**Files:**
- Modify: `codeshape/lib/adapters.sh`
- Modify: `codeshape/test/adapters.test.sh`

**Interfaces:**
- Consumes: none new.
- Produces: extends `analyze_file` so that when `lizard` is installed AND claims the file's extension, it is preferred over scc because it yields real per-function `ccn`, `len` (NLOC), and `args` (parameter count). File rollup = worst-offending function per metric. `nesting` stays `0` (lizard does not report it) and `dup_ratio` stays `0` for now. scc remains the fallback.

- [ ] **Step 1: Write the failing test**

```bash
# append to codeshape/test/adapters.test.sh, before the final PASS/FAIL echo
if command -v lizard >/dev/null 2>&1; then
  TMP2="$(mktemp -d)"
  cat > "$TMP2/f.py" <<'PY'
def big(a, b, c, d, e):
    if a:
        if b:
            for i in range(c):
                if d and e:
                    return i
    return 0
PY
  rec="$(analyze_file "$TMP2/f.py" "f.py")"
  ok "lizard record is valid JSON"           'printf "%s" "$rec" | jq -e . >/dev/null 2>&1'
  ok "lizard captures the 5-arg function"    'printf "%s" "$rec" | jq -e "[.fns[].args] | max == 5" >/dev/null'
  ok "lizard ccn reflects branching (>1)"    'printf "%s" "$rec" | jq -e "[.fns[].ccn] | max > 1" >/dev/null'
  rm -rf "$TMP2"
else
  skip "lizard not installed — per-function enrichment tests skipped"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash codeshape/test/adapters.test.sh`
Expected: FAIL (if lizard installed) — args are not captured because only the scc path exists. (If lizard absent → `skip`, so re-derive the failure by temporarily asserting; otherwise proceed — the enrichment code is still required for correctness.)

- [ ] **Step 3: Write minimal implementation**

Insert a lizard branch at the TOP of `analyze_file` (before the scc branch), so lizard wins when it claims the file:

```bash
  if command -v lizard >/dev/null 2>&1; then
    # lizard --csv emits one row per function:
    #   nloc,ccn,token,param,length,location,file,function,long_name,start,end
    local csv
    csv="$(lizard --csv "$abs" 2>/dev/null)" || csv=""
    if [[ -n "$csv" ]]; then
      local rec
      rec="$(printf '%s\n' "$csv" | awk -F, 'NF>=5{print $2"\t"$5"\t"$4}' \
        | jq -R -s --arg p "$rel" '
            [ split("\n")[] | select(length>0) | split("\t")
              | { ccn:(.[0]|tonumber), len:(.[1]|tonumber), args:(.[2]|tonumber),
                  name:"fn", nesting:0 } ] as $fns
            | select(($fns|length) > 0)
            | { path:$p, lang:"lizard", loc:([$fns[].len]|add),
                fns:$fns, dup_ratio:0 }' 2>/dev/null)"
      if [[ -n "$rec" && "$rec" != "null" ]]; then printf '%s\n' "$rec"; return 0; fi
    fi
  fi
```

*(Implementer note: confirm lizard's `--csv` column order on your version; the awk `$2/$5/$4` map is ccn/length/param per the documented header above. Adjust indices if the header differs.)*

- [ ] **Step 4: Run test to verify it passes**

Run: `bash codeshape/test/adapters.test.sh`
Expected: PASS — lizard asserts pass (or `skip` if absent); scc asserts from Task 4 still pass.

- [ ] **Step 5: Commit**

```bash
git add codeshape/lib/adapters.sh codeshape/test/adapters.test.sh
git commit -m "feat(codeshape): lizard adapter for per-function metrics"
```

---

### Task 6: churn + aggregator + CLI entrypoint

**Files:**
- Create: `codeshape/codeshape`  (the executable CLI)
- Create: `codeshape/test/cli.test.sh`

**Interfaces:**
- Consumes: `lib/_common.sh`, `lib/config.sh`, `lib/scorer.sh`, `lib/adapters.sh`.
- Produces: the `codeshape` executable. Usage: `codeshape [path] [--since N] [--files] [--json|--csv]`. Default output = three KPIs + G/Y/R counts + coverage. JSON `data` shape: `{ hotspot_health, average_health, worst:{path,score}, tiers:{green,yellow,red}, coverage:{scored,skipped,total,skipped_languages}, files:[{path,score,loc,change_count,tier}] }`.

- [ ] **Step 1: Write the failing test**

```bash
# codeshape/test/cli.test.sh
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok() { if eval "$2"; then echo "ok - $1"; PASS=$((PASS+1)); else echo "FAIL - $1"; FAIL=$((FAIL+1)); fi; }

# Outside a git repo, --json emits a NOT_FOUND envelope on stdout.
NON="$(mktemp -d)"
out="$(cd "$NON" && "$DIR/codeshape" --json 2>/dev/null)"
ok "outside repo → parseable JSON" 'printf "%s" "$out" | jq -e . >/dev/null 2>&1'
ok "outside repo → NOT_FOUND"      '[[ "$(printf "%s" "$out" | jq -r .code)" == "NOT_FOUND" ]]'
rm -rf "$NON"

# Bad --since → BAD_ARGS envelope.
REPO="$(mktemp -d)"
( cd "$REPO" && git init -q && git config user.email t@t.co && git config user.name t \
  && echo 'package main' > m.go && git add -A && git commit -qm init )
bad="$(cd "$REPO" && "$DIR/codeshape" --since abc --json 2>/dev/null)"
ok "bad --since → BAD_ARGS" '[[ "$(printf "%s" "$bad" | jq -r .code)" == "BAD_ARGS" ]]'

# Happy path (only if an adapter is installed): envelope has the KPI + coverage keys.
if [[ -n "$(cd "$REPO" && bash -c 'source "'"$DIR"'/lib/adapters.sh"; adapter_available')" ]]; then
  good="$(cd "$REPO" && "$DIR/codeshape" --json 2>/dev/null)"
  ok "envelope metric is codeshape"     '[[ "$(printf "%s" "$good" | jq -r .metric)" == "codeshape" ]]'
  ok "data has average_health"          'printf "%s" "$good" | jq -e ".data.average_health != null" >/dev/null'
  ok "data has coverage.total"          'printf "%s" "$good" | jq -e ".data.coverage.total >= 1" >/dev/null'
  ok "data has tiers object"            'printf "%s" "$good" | jq -e ".data.tiers | has(\"green\")" >/dev/null'
else
  echo "skip - no adapter installed; happy-path assertions skipped"
fi
rm -rf "$REPO"

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash codeshape/test/cli.test.sh`
Expected: FAIL — `codeshape` executable does not exist.

- [ ] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# codeshape — score the current health of a codebase (local working tree).
# Usage: codeshape [path] [--since N] [--files] [--json|--csv]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/_common.sh"
source "$HERE/lib/config.sh"
source "$HERE/lib/scorer.sh"
source "$HERE/lib/adapters.sh"

usage() { cat <<EOF
Usage: codeshape [path] [--since N] [--files] [--json|--csv]
  path       subdirectory to scope the scan to (default: repo root)
  --since N  churn lookback window in days (default: 90)
  --files    list per-file scores (worst first) instead of the KPI summary
  --json     machine-readable envelope
  --csv      per-file CSV
Requires: git, jq, and at least one of: scc, lizard, radon, gocyclo
EOF
}

JSON=false; CSV=false; FILES=false; SINCE=90; SCOPE=""
need_value() { [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; exit 1; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=true ;;
    --csv)  CSV=true ;;
    --files) FILES=true ;;
    --since)   need_value "$@"; SINCE="$2"; shift ;;
    --since=*) SINCE="${1#*=}" ;;
    *) SCOPE="$1" ;;
  esac
  shift
done

[[ "$JSON" == "true" ]] && json_preflight_local
require_git_repo || { usage >&2; exit 1; }
resolve_local_repo
load_config

if ! [[ "$SINCE" =~ ^[0-9]+$ ]]; then
  [[ "$JSON" == "true" ]] && json_error BAD_ARGS "--since must be a non-negative integer"
  echo "Error: --since must be a non-negative integer" >&2; exit 1
fi

if [[ -z "$(adapter_available)" ]]; then
  [[ "$JSON" == "true" ]] && json_error DEP_MISSING "no analyzer found; install one of: scc, lizard, radon, gocyclo"
  echo "Error: no analyzer found (install scc, lizard, radon, or gocyclo)" >&2; exit 1
fi

# Churn: commits per path in the window (same idiom as engleader hotspots.sh).
declare -A churn
while IFS=$'\t' read -r c p; do [[ -n "$p" ]] && churn["$p"]="$c"; done < <(
  git -C "$ROOT" log --since="${SINCE} days ago" --pretty=format: --name-only 2>/dev/null \
    | awk '$0!=""{n[$0]++} END{for(k in n) print n[k]"\t"k}' || true)

# Score each tracked file; collect scored records + coverage.
scored="";   scored_n=0; skipped_n=0; total_n=0
declare -A skip_langs
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  [[ -n "$SCOPE" && "$rel" != "$SCOPE"* ]] && continue
  total_n=$((total_n+1))
  abs="$ROOT/$rel"
  [[ -f "$abs" ]] || { skipped_n=$((skipped_n+1)); continue; }
  rec="$(analyze_file "$abs" "$rel" 2>/dev/null)" || {
    skipped_n=$((skipped_n+1))
    ext="${rel##*.}"; skip_langs["$ext"]=1
    continue
  }
  # worst-offending-function rollup
  read -r ccn len args nest loc <<<"$(printf '%s' "$rec" | jq -r '
    [.fns[].ccn]|max as $c | [.fns[].len]|max as $l | [.fns[].args]|max as $a |
    [.fns[].nesting]|max as $n | "\($c) \($l) \($a) \($n) \(.loc)"')"
  dup="$(printf '%s' "$rec" | jq -r '.dup_ratio')"
  s="$(score_record "$ccn" "$len" "$args" "$nest" "$dup")"
  cc="${churn[$rel]:-0}"
  scored+="${s}	${loc}	${cc}	${rel}"$'\n'
  scored_n=$((scored_n+1))
done < <(git -C "$ROOT" ls-files)

scored="$(printf '%s' "$scored" | grep -v '^$' || true)"

# Build files JSON (sorted worst-first) once; reuse for every output mode.
files_json="$(printf '%s\n' "$scored" | sort -t$'\t' -k1,1n | jq -R -s \
  --argjson g "$TIER_GREEN" --argjson y "$TIER_YELLOW" '
  [ split("\n")[] | select(length>0) | split("\t")
    | { score:(.[0]|tonumber), loc:(.[1]|tonumber),
        change_count:(.[2]|tonumber), path:.[3] }
    | .tier = (if .score >= $g then "green" elif .score >= $y then "yellow" else "red" end) ]')"

skip_langs_json="$(printf '%s\n' "${!skip_langs[@]}" | jq -R -s 'split("\n")|map(select(length>0))')"

data="$(jq -n --argjson files "$files_json" --argjson cf "$CHURN_FLOOR" \
  --argjson scored "$scored_n" --argjson skipped "$skipped_n" --argjson total "$total_n" \
  --argjson skiplangs "$skip_langs_json" '
  ($files | map(select(.loc>0))) as $f
  | ($f | map(.loc) | add // 0) as $totloc
  | ($f | map(select(.change_count >= $cf))) as $hot
  | ($hot | map(.loc) | add // 0) as $hotloc
  | {
      hotspot_health: (if ($hot|length)>0 and $hotloc>0
        then (($hot | map(.score*.loc) | add) / $hotloc) else null end),
      average_health: (if ($f|length)>0 and $totloc>0
        then (($f | map(.score*.loc) | add) / $totloc) else null end),
      worst: ($f | min_by(.score) | if . == null then null else {path,score} end),
      tiers: { green:($f|map(select(.tier=="green"))|length),
               yellow:($f|map(select(.tier=="yellow"))|length),
               red:($f|map(select(.tier=="red"))|length) },
      coverage: { scored:$scored, skipped:$skipped, total:$total, skipped_languages:$skiplangs },
      files: $files
    }
  | .hotspot_health = (if .hotspot_health==null then null else (.hotspot_health*10|round/10) end)
  | .average_health = (if .average_health==null then null else (.average_health*10|round/10) end)')"

if [[ "$JSON" == "true" ]]; then emit_json "codeshape" "$SINCE" "$data"; exit 0; fi

if [[ "$CSV" == "true" ]]; then
  echo "File,Score,LoC,Changes,Tier"
  printf '%s' "$data" | jq -r '.files[] | [.path,.score,.loc,.change_count,.tier] | @csv'
  exit 0
fi

if [[ "$FILES" == "true" ]]; then
  printf '%s' "$data" | jq -r '.files[] | "\(.score)  \(.tier|ascii_upcase[0:1])  \(.path)"'
  exit 0
fi

# Default: KPI summary.
printf '%s' "$data" | jq -r '
  "Code Health — \(.coverage.scored) of \(.coverage.total) files scored",
  "──────────────────────────────────────────",
  "  Hotspot Health : \(.hotspot_health // "n/a")",
  "  Average Health : \(.average_health // "n/a")",
  "  Worst          : \(if .worst then "\(.worst.score)  \(.worst.path)" else "n/a" end)",
  "  Green/Yellow/Red: \(.tiers.green) / \(.tiers.yellow) / \(.tiers.red)",
  (if (.coverage.skipped>0) then "  Skipped        : \(.coverage.skipped) files (\(.coverage.skipped_languages|join(\", \")))" else empty end)'
```

Then `chmod +x codeshape/codeshape`.

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x codeshape/codeshape && bash codeshape/test/cli.test.sh`
Expected: PASS — envelope + BAD_ARGS + NOT_FOUND asserts pass; happy-path asserts pass if an adapter is installed, else `skip`.

- [ ] **Step 5: Commit**

```bash
git add codeshape/codeshape codeshape/test/cli.test.sh
git commit -m "feat(codeshape): churn + aggregator + CLI entrypoint"
```

---

### Task 7: Test runner + docs

**Files:**
- Create: `codeshape/test/run.sh`
- Modify: `codeshape/README.md`
- Create: `codeshape/docs/json-contract.md`

**Interfaces:**
- Consumes: all `test/*.test.sh`.
- Produces: `test/run.sh` runs every `*.test.sh` and exits non-zero if any fails. Docs describe the JSON envelope + `data` fields and config knobs.

- [ ] **Step 1: Write the failing test**

```bash
# codeshape/test/run.sh
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
for t in "$DIR"/*.test.sh; do
  echo "== $t =="
  bash "$t" || fail=1
done
exit "$fail"
```

- [ ] **Step 2: Run to verify it runs the suite**

Run: `bash codeshape/test/run.sh`
Expected: runs common/config/scorer/adapters/cli suites; exits 0 when all pass.

- [ ] **Step 3: Write the docs**

Add to `codeshape/README.md`: usage examples (`codeshape`, `codeshape --files`, `codeshape --since 180 --json`), the requirements line, and a "Configuration" section documenting `.codeshaperc` keys (`T_CCN`, `T_LEN`, `T_ARGS`, `T_NEST`, `W_*`, `TIER_GREEN`, `TIER_YELLOW`, `CHURN_FLOOR`) with their defaults.

Create `codeshape/docs/json-contract.md` documenting the envelope (`metric="codeshape"`, `repo`, `window_days`, `generated_at`, `data`) and every `data` field: `hotspot_health`, `average_health`, `worst{path,score}`, `tiers{green,yellow,red}`, `coverage{scored,skipped,total,skipped_languages}`, `files[]{path,score,loc,change_count,tier}`. Note error envelope `{error,code}` and the codes `NOT_FOUND`/`BAD_ARGS`/`DEP_MISSING`.

- [ ] **Step 4: Verify**

Run: `bash codeshape/test/run.sh`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add codeshape/test/run.sh codeshape/README.md codeshape/docs/json-contract.md
git commit -m "docs(codeshape): test runner + README + JSON contract"
```

---

### Task 8: MCP server (codeshape_health tool)

**Files:**
- Create: `codeshape/mcp/tools.ts`
- Create: `codeshape/mcp/tools.test.ts`
- Create: `codeshape/mcp/runner.ts`
- Create: `codeshape/mcp/index.ts`
- Create: `codeshape/mcp/package.json`

**Interfaces:**
- Consumes: the `codeshape` CLI (spawned with `--json`).
- Produces: an MCP server exposing one tool, `codeshape_health`, with params `directory` (optional, used as cwd), `since` (optional number), `files` (optional boolean). Mirrors engleader's `mcp/tools.ts` `buildArgs`/`schemaFor` pattern, restricted to the single local tool.

- [ ] **Step 1: Write the failing test**

```typescript
// codeshape/mcp/tools.test.ts
import { test, expect } from "bun:test";
import { TOOL, buildArgs, schemaFor } from "./tools.ts";

test("tool name is codeshape_health", () => {
  expect(TOOL.name).toBe("codeshape_health");
});

test("buildArgs omits directory (it becomes cwd) and orders --since / --files", () => {
  expect(buildArgs({})).toEqual([]);
  expect(buildArgs({ directory: "/repo" })).toEqual([]);
  expect(buildArgs({ directory: "/repo", since: 180 })).toEqual(["--since", "180"]);
  expect(buildArgs({ since: 90, files: true })).toEqual(["--since", "90", "--files"]);
});

test("schemaFor exposes directory/since/files, not repo", () => {
  const shape = schemaFor();
  expect(shape.directory).toBeDefined();
  expect(shape.since).toBeDefined();
  expect(shape.files).toBeDefined();
  expect((shape as Record<string, unknown>).repo).toBeUndefined();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd codeshape/mcp && bun test tools.test.ts`
Expected: FAIL — `tools.ts` does not exist.

- [ ] **Step 3: Write minimal implementation**

```typescript
// codeshape/mcp/tools.ts
import { z } from "zod";

export const TOOL = {
  name: "codeshape_health",
  description:
    "Score the current health of a local codebase — a CodeScene-style 1–10 " +
    "deduction score per file, rolled up to Hotspot Health, Average Health, " +
    "and the worst file. Analyzes the working tree; needs an analyzer (scc/lizard) installed.",
};

export function buildArgs(params: Record<string, unknown>): string[] {
  const args: string[] = [];
  if (params.since !== undefined && params.since !== null) {
    args.push("--since", String(params.since));
  }
  if (params.files === true) args.push("--files");
  return args;
}

export function schemaFor(): Record<string, z.ZodTypeAny> {
  return {
    directory: z.string().optional()
      .describe("Path to the local git repository to analyze (defaults to the server cwd)"),
    since: z.number().optional().describe("Churn lookback window in days (default: 90)"),
    files: z.boolean().optional().describe("Return per-file scores instead of the KPI summary"),
  };
}
```

```typescript
// codeshape/mcp/runner.ts
import { spawn } from "node:child_process";

export function runCodeshape(args: string[], cwd?: string): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const bin = process.env.CODESHAPE_BIN || "codeshape";
    const child = spawn(bin, [...args, "--json"], { cwd });
    let out = "", err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", reject);
    child.on("close", () => {
      try {
        const parsed = JSON.parse(out);
        if (parsed && parsed.code) reject(new Error(`[${parsed.code}] ${parsed.error}`));
        else resolve(parsed);
      } catch {
        reject(new Error(err || "codeshape produced no parseable JSON"));
      }
    });
  });
}
```

```typescript
// codeshape/mcp/index.ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { TOOL, buildArgs, schemaFor } from "./tools.ts";
import { runCodeshape } from "./runner.ts";

const server = new McpServer({ name: "codeshape", version: "0.1.0" });

server.tool(TOOL.name, TOOL.description, schemaFor(), async (params) => {
  const data = await runCodeshape(buildArgs(params), params.directory as string | undefined);
  return { content: [{ type: "text", text: JSON.stringify(data) }] };
});

await server.connect(new StdioServerTransport());
```

```json
{
  "name": "codeshape-mcp",
  "module": "index.ts",
  "type": "module",
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.0.0",
    "zod": "^3.23.0"
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd codeshape/mcp && bun install && bun test tools.test.ts`
Expected: PASS — 3 tests green.

- [ ] **Step 5: Commit**

```bash
git add codeshape/mcp/
git commit -m "feat(codeshape): MCP server exposing codeshape_health"
```

---

## Self-Review

**Spec coverage:**
- §1 Concept/positioning → README (Task 1/7). ✓
- §2 Architecture (adapters/scorer/churn/aggregator) → Tasks 4–5 (adapters), 3 (scorer), 6 (churn+aggregator). ✓
- §3 Data flow + deduction scoring + tiers → Task 3 (scorer), Task 6 (flow, tiers). ✓
- §4 Config (thresholds/weights/cutoffs/churn_floor, `.codeshaperc` override) → Task 2. ✓
- §5 Error handling (NOT_FOUND/DEP_MISSING/BAD_ARGS, per-file skip, empty repo) → Task 1 (envelope), Task 6 (all three codes + skip). ✓
- §6 Testing (scorer/adapters/aggregator/integration/MCP) → Tasks 3,4,5,6,8 tests. ✓
- §7 MCP surface (`codeshape_health`, `local`, since/files) → Task 8. ✓
- §8 Non-goals (no heuristic fallback, no cohesion, no coupling) → honored (adapters skip on unclaimed; no LCOM; no imports of other tools). ✓
- §9 Open details → resolved: rollup=worst-offender (Global Constraints + Task 6), config format=sourced KEY=value `.codeshaperc` (Task 2), adapter precedence=lizard>scc (Task 5), dup_ratio=0 for scc/lizard v1 (documented, Tasks 4/5). ✓

**Placeholder scan:** No TBD/TODO in steps. Two "implementer notes" ask the engineer to confirm exact scc/lizard field names against their installed version — these are verification instructions with concrete defaults given, not placeholders.

**Type consistency:** Normalized record shape (`path/lang/loc/fns[{name,ccn,len,args,nesting}]/dup_ratio`) is identical across Global Constraints, Task 4, Task 5, and consumed unchanged in Task 6's jq rollup. `buildArgs`/`schemaFor` signatures in Task 8 match its test. Config globals (`T_*`,`W_*`,`TIER_*`,`CHURN_FLOOR`) defined in Task 2 and consumed by Tasks 3/6 by the same names. ✓

**Known soft spots for the implementer** (flagged, not placeholders): exact scc `--by-file --format json` field names and lizard `--csv` column order vary by version — both tasks tell the implementer to verify and adjust the jq/awk field paths, and the tests assert record *shape* not tool internals, so they stay green across versions.
