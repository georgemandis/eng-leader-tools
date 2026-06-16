import { z } from "zod";

// A numeric positional param: the param name on the tool, and the order it
// appears in the eng command line after `repo`.
type NumParam = { key: string; describe: string };

export type ToolDef = {
  name: string;          // MCP tool name (eng_*)
  command: string;       // eng subcommand
  description: string;
  teamAware: boolean;    // exposes a `team` param mapped to ENG_TEAM
  raw?: boolean;         // return stdout text instead of parsed JSON
  numParams: NumParam[]; // ordered numeric positionals after repo
  prNumber?: boolean;    // requires a pr_number positional (pull-discussion)
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
];

// Turn validated params into the ordered positional argument array for eng.
// Positionals are order-sensitive: once one is omitted, no later positional
// may be supplied (eng would mis-read it as the earlier slot).
export function buildArgs(tool: ToolDef, params: Record<string, unknown>): string[] {
  if (params.repo === undefined || params.repo === null) {
    throw new Error("buildArgs: 'repo' is required");
  }
  const args: string[] = [String(params.repo)];
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
  return args;
}

// Build the zod schema object for a tool's MCP params.
export function schemaFor(tool: ToolDef): Record<string, z.ZodTypeAny> {
  const shape: Record<string, z.ZodTypeAny> = {
    repo: z.string().describe("Repository as owner/repo"),
  };
  if (tool.prNumber) shape.pr_number = z.number().describe("Pull request number");
  for (const p of tool.numParams) {
    shape[p.key] = z.number().optional().describe(p.describe);
  }
  if (tool.teamAware) {
    shape.team = z.string().optional().describe("Filter to members of this GitHub Team slug");
  }
  return shape;
}
