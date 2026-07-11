# codeshape — Design Spec

**Date:** 2026-07-08
**Status:** Approved (brainstorm), pending implementation plan

## 1. Concept & Positioning

`codeshape` is a standalone, local-first CLI (plus MCP server) that scores the
**current shape of the code** — independent of who wrote it or how the team
ships. It is a third measurement axis alongside two existing tools:

| Tool | View | Data source | Question |
|---|---|---|---|
| engleader.tools | Manager, outside | GitHub API | How is the team shipping? |
| engsight | IC, passive | Git hook event stream | How am I working? |
| **codeshape** | **The artifact itself** | **Working tree + git log** | **What shape is the code in?** |

It is **self-contained**: it derives its own churn from `git log`, so the
`score × churn` hotspot-weighting works with zero runtime dependency on the
other two tools. It shares their ethos — a small tool orchestrating existing
analyzers — and their MCP/JSON-envelope conventions, but couples to neither at
runtime.

### Inspiration: CodeScene Code Health

CodeScene's Code Health is a 1–10 score aggregated from 25+ source-level
factors (cyclomatic complexity, nesting depth, function length, argument count,
duplication, cohesion). It is a **deduction model** over the parsed source, and
it reports **three project KPIs** rather than one average (to prevent a large
healthy file from masking a small toxic one). `codeshape` adopts both ideas: a
deduction-based per-file score and CodeScene's three-KPI project rollup.

## 2. Architecture

Four well-bounded, independently testable units:

```
codeshape  (bash CLI, mirrors engleader's src/*.sh shape)
│
├─ 1. adapters/       "what are the raw metrics for these files?"
│     probe PATH → pick best available analyzer per language
│     scc | lizard | radon | gocyclo, each normalized to a common record:
│       { path, lang, loc, fns:[{name, ccn, len, args, nesting}], dup_ratio }
│     A file whose language no adapter claims is SKIPPED (not scored).
│
├─ 2. scorer          "what's this file's health?"  (PURE function)
│     start 10.0 → subtract weighted penalties over thresholds → clamp [1,10]
│     thresholds + weights from a config file (tunable, documented)
│
├─ 3. churn           "how often does this file change?"
│     git log --since → per-path change count  (same idiom as hotspots.sh)
│
└─ 4. aggregator      "what's the project view?"
      three KPIs + green/yellow/red counts + coverage block
      --files drops to a ranked per-file list (worst first)
```

**The adapter interface is the load-bearing boundary.** Every adapter, whatever
its underlying tool, returns the same normalized record shape. The scorer,
churn, and aggregator never know which analyzer ran. This isolation is what
keeps "pluggable adapters" from becoming a mess: adding a new analyzer later
means writing one adapter that emits the normalized shape — nothing else
changes.

**The scorer is a pure function** of a normalized record + config (no I/O), so
it is trivially unit-testable with fixture records.

## 3. Data Flow

```
codeshape [path] [--since 90d] [--files] [--json|--csv]
   │
   ├─ resolve repo root (git rev-parse), list tracked files (git ls-files)
   ├─ churn:     git log --since → {path: change_count}
   ├─ adapters:  for each file, first adapter that claims its language →
   │             normalized record;  no claimer → skipped[]
   ├─ scorer:    normalized record → score ∈ [1,10]  (pure, config-driven)
   └─ aggregator:
         Hotspot Health = LoC-weighted avg over files with change_count ≥ churn_floor
         Average Health = LoC-weighted avg over all scored files
         Worst          = min score (with its path)
         coverage       = { scored, skipped, total, skipped_languages }
         → default output: three KPIs + G/Y/R counts + coverage
         → --files output: ranked per-file list (worst first)
```

### Scoring model (deduction)

Each file starts at `10.0`. For each metric that exceeds its threshold, subtract
a weighted penalty proportional to the overage; then clamp to `[1.0, 10.0]`.

```
score = 10
  − w_ccn  · over(ccn,     T_ccn)
  − w_len  · over(len,     T_len)
  − w_nest · over(nesting, T_nest)
  − w_args · over(args,    T_args)
  − w_dup  · dup_ratio
clamp to [1, 10]
```

where `over(x, T) = max(0, x − T)` (scaled per the config). Function-level
metrics (ccn, len, args, nesting) are rolled up to the file by the
**worst-offending function** for v1 — the file's `ccn` is its most-complex
function's `ccn`, etc. (A weighted blend is tracked as a possible refinement in
Open Implementation Details.)

### Green / Yellow / Red tiers

Derived from the final score via configured cutoffs (e.g. `≥8 green`,
`≥5 yellow`, else `red`). Reported as counts in the project view.

## 4. Configuration

A documented default config ships in the repo and is overridable via a dotfile
(e.g. `.codeshape.toml` / `.codeshaperc`, format TBD in the plan). Default
thresholds are CodeScene-ish:

| Metric | Default threshold |
|---|---|
| Cyclomatic complexity (ccn) | > 10 |
| Function length (len) | > 60 lines |
| Argument count (args) | > 4 |
| Nesting depth | > 3 |
| Duplication ratio | penalized proportionally |

Weights (`w_ccn`, `w_len`, …), the score→tier cutoffs, and the `churn_floor`
(minimum change count to count as a "hotspot") are all config values.

## 5. Error Handling

Follows engleader.tools' JSON-envelope convention (`{error, code}` on stdout in
JSON mode; usage to stderr otherwise). Codes reused: `NOT_FOUND`, `BAD_ARGS`,
`DEP_MISSING`.

- **Not a git repo** → `NOT_FOUND`.
- **No adapters installed at all** → `DEP_MISSING`, naming what to install
  (`scc`, `lizard`, …). Without any adapter there is nothing to score, so this
  fails loudly.
- **Bad args** (e.g. `--since garbage`) → `BAD_ARGS`.
- **An analyzer crashes on one file** → that file joins `skipped[]` with a
  reason; the run continues. One bad file never sinks the whole score.
- **Empty repo / all files skipped** → valid envelope with zeroed KPIs and
  `coverage.scored: 0`. Not an error.

Coverage is always reported so skipped files are explicit, never silently
dropped from the denominator's story.

## 6. Testing

- **scorer** — fixture normalized-records → assert exact scores (locks the
  deduction math + clamping).
- **adapters** — check in tiny sample source files per language; assert
  normalized output. Skip a given adapter's test when its binary is absent, so
  CI degrades gracefully.
- **aggregator** — synthetic file+churn sets → assert the three KPIs and the
  coverage block.
- **integration** — run `codeshape` against a fixture repo; assert the JSON
  envelope shape and that skipped files are counted, not scored.
- **MCP** — buildArgs/schema test for the new tool (engleader `tools.test.ts`
  style).

## 7. MCP Surface

One tool, `codeshape_health`, exposed via its own MCP server that mirrors
engleader's `mcp/` structure (declarative `ToolDef`; generic registration
loop). Characteristics:

- `local: true` — takes a `directory` used as the child cwd (no `repo`).
- `numParams: [since_days, churn_floor]`.
- `--files` exposed as a boolean param.
- Returns the same JSON envelope the CLI emits.

## 8. Non-Goals (v1)

- **No line-based heuristic fallback.** Files with no matching adapter are
  skipped and reported under coverage, not approximately scored.
- **No cohesion/LCOM4 or "brain class" detection.** v1 covers the
  function-level metrics the reused analyzers provide directly.
- **No runtime coupling to engleader.tools or engsight.** Sharing the score
  with them is possible future work, explicitly out of scope here.

## 9. Open Implementation Details (for the plan)

- File-level rollup of function metrics (worst-offender vs. weighted blend).
- Config file format and discovery order.
- Exact adapter selection precedence when multiple analyzers cover one language.
- `dup_ratio` source per adapter (not every analyzer reports duplication).
