import { z } from "zod";

// A numeric positional param: the param name on the tool, and the order it
// appears in the eng command line after `repo`.
type NumParam = { key: string; describe: string };

// A string positional param (e.g. an optional scope path for local-tree tools).
type StrParam = { key: string; describe: string };

export type ToolDef = {
  name: string;          // MCP tool name (eng_*)
  command: string;       // eng subcommand
  description: string;
  teamAware: boolean;    // exposes a `team` param mapped to ENG_TEAM
  raw?: boolean;         // return stdout text instead of parsed JSON
  numParams: NumParam[]; // ordered numeric positionals after repo
  prNumber?: boolean;    // requires a pr_number positional (pull-discussion)
  // Local-tree tools (hotspots, todo-debt, test-ratio) analyze the checked-out
  // repository instead of the GitHub API. They take a `directory` (the repo to
  // run in, passed as the child process cwd) instead of a `repo` argument, and
  // ignore team filtering.
  local?: boolean;
  pathParam?: StrParam;  // optional trailing string positional (scope path)
};

const WINDOW = (def: number): NumParam => ({
  key: "window_days",
  describe: `Lookback window in days (default: ${def})`,
});
const COUNT: NumParam = { key: "count", describe: "Number of recent PRs to sample" };
const LIMIT: NumParam = { key: "limit", describe: "Max open PRs to consider" };

export const TOOLS: ToolDef[] = [
  // DORA
  { name: "eng_lead_time", command: "lead-time", teamAware: true,
    description: "Average time from PR creation to merge for a repo.",
    numParams: [WINDOW(30)] },
  { name: "eng_change_failure_rate", command: "change-failure-rate", teamAware: false,
    description: "Percentage of merged PRs flagged as rollbacks or hotfixes.",
    numParams: [WINDOW(30)] },
  { name: "eng_deploy_frequency", command: "deploy-frequency", teamAware: false,
    description: "How often releases/tags ship, with DORA tier assessment.",
    numParams: [WINDOW(90)] },
  // PR health
  { name: "eng_review_time", command: "review-time", teamAware: true,
    description: "Time to first review and time to merge across recent PRs.",
    numParams: [COUNT] },
  { name: "eng_pr_size", command: "pr-size", teamAware: true,
    description: "PR size distribution (XS-XL) correlated with review time.",
    numParams: [COUNT] },
  { name: "eng_files_per_pr", command: "files-per-pr", teamAware: true,
    description: "Files changed per merged PR.",
    numParams: [COUNT] },
  { name: "eng_stale_prs", command: "stale-prs", teamAware: true,
    description: "Open PRs grouped by age, highlighting work needing attention.",
    numParams: [LIMIT] },
  { name: "eng_review_load", command: "review-load", teamAware: true,
    description: "How review work is distributed across contributors.",
    numParams: [COUNT] },
  // Codebase & contributors
  { name: "eng_code_churn", command: "code-churn", teamAware: false,
    description: "File hotspots — files changed repeatedly across PRs.",
    numParams: [WINDOW(30), { key: "min_changes", describe: "Minimum changes to count as a hotspot" }] },
  { name: "eng_contributor_patterns", command: "contributor-patterns", teamAware: true,
    description: "Per-contributor PR size patterns (focused vs broad-scope).",
    numParams: [COUNT] },
  { name: "eng_lottery_factor", command: "lottery-factor", teamAware: false,
    description: "Knowledge concentration risk — files with only 1-2 contributors.",
    numParams: [COUNT] },
  { name: "eng_dependency_changes", command: "dependency-changes", teamAware: false,
    description: "Tracks dependency update PRs and flags security updates.",
    numParams: [WINDOW(30)] },
  // Discussion (raw text)
  { name: "eng_pull_discussion", command: "pull-discussion", teamAware: false, raw: true,
    description: "Full PR discussion (comments, reviews, files) as structured text.",
    numParams: [], prNumber: true },
  // Code health (local working tree — pass `directory`, not `repo`)
  { name: "eng_hotspots", command: "hotspots", teamAware: false, local: true,
    description:
      "Refactoring targets in a local repo — files high in both change " +
      "frequency (churn) and code size. Analyzes the working tree, not the API.",
    numParams: [WINDOW(90), { key: "min_changes", describe: "Minimum commits touching a file (default: 3)" }] },
  { name: "eng_todo_debt", command: "todo-debt", teamAware: false, local: true,
    description:
      "Counts and locates TODO/FIXME/HACK/XXX debt markers across a local " +
      "repo's tracked files.",
    numParams: [], pathParam: { key: "path", describe: "Optional subdirectory to scope the scan to" } },
  { name: "eng_test_ratio", command: "test-ratio", teamAware: false, local: true,
    description:
      "Ratio of test code to source code in a local repo, by file count and " +
      "lines of code, with a per-directory breakdown.",
    numParams: [], pathParam: { key: "path", describe: "Optional subdirectory to scope to" } },
];

// Turn validated params into the ordered positional argument array for eng.
// Positionals are order-sensitive: once one is omitted, no later positional
// may be supplied (eng would mis-read it as the earlier slot).
export function buildArgs(tool: ToolDef, params: Record<string, unknown>): string[] {
  const args: string[] = [];
  if (tool.local) {
    // Local-tree tools take no `repo`; the `directory` param is applied as the
    // child process cwd by the caller, not as a positional argument.
  } else {
    if (params.repo === undefined || params.repo === null) {
      throw new Error("buildArgs: 'repo' is required");
    }
    args.push(String(params.repo));
  }
  if (tool.prNumber) args.push(String(params.pr_number));

  let sawGap = false;
  for (const p of tool.numParams) {
    const v = params[p.key];
    const present = v !== undefined && v !== null;
    if (present && sawGap) {
      throw new Error(
        `buildArgs: '${p.key}' was provided but an earlier positional ` +
          `argument was omitted; supply the earlier argument(s) too.`,
      );
    }
    if (present) args.push(String(v));
    else sawGap = true;
  }

  if (tool.pathParam) {
    const v = params[tool.pathParam.key];
    if (v !== undefined && v !== null) args.push(String(v));
  }
  return args;
}

// Build the zod schema object for a tool's MCP params.
export function schemaFor(tool: ToolDef): Record<string, z.ZodTypeAny> {
  const shape: Record<string, z.ZodTypeAny> = {};
  if (tool.local) {
    shape.directory = z
      .string()
      .optional()
      .describe(
        "Path to the local git repository to analyze " +
          "(defaults to the server's working directory)",
      );
  } else {
    shape.repo = z.string().describe("Repository as owner/repo");
  }
  if (tool.prNumber) shape.pr_number = z.number().describe("Pull request number");
  for (const p of tool.numParams) {
    shape[p.key] = z.number().optional().describe(p.describe);
  }
  if (tool.pathParam) {
    shape[tool.pathParam.key] = z.string().optional().describe(tool.pathParam.describe);
  }
  if (tool.teamAware) {
    shape.team = z.string().optional().describe("Filter to members of this GitHub Team slug");
  }
  return shape;
}
