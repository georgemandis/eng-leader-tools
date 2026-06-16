import { which } from "bun";

type Env = Record<string, string | undefined>;

/**
 * Resolve the `eng` binary: ENG_BIN override first, then PATH lookup.
 * `findOnPath` is injectable for testing; defaults to Bun's `which`.
 */
export function resolveEngBin(
  env: Env = process.env,
  findOnPath: (name: string) => string | null = (name) => which(name) ?? null,
): string {
  if (env.ENG_BIN) return env.ENG_BIN;
  const found = findOnPath("eng");
  if (found) return found;
  throw new Error(
    "`eng` not found. Install it with `brew install eng-leader-tools` " +
      "(macOS/Linux) or `scoop install eng-leader-tools` (Windows), or set " +
      "the ENG_BIN environment variable to its path.",
  );
}

type SpawnResult = { stdout: string; stderr: string; exitCode: number };
type SpawnFn = (argv: string[], env: Env) => Promise<SpawnResult>;

export type RunOpts = { team?: string; raw?: boolean };

// Default spawn implementation using Bun.spawn.
const defaultSpawn: SpawnFn = async (argv, env) => {
  const proc = Bun.spawn(argv, {
    env: env as Record<string, string>,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const exitCode = await proc.exited;
  return { stdout, stderr, exitCode };
};

/**
 * Run `eng <command> <...positional> --json` and return the parsed envelope.
 * On non-zero exit, throws the {error,code} object's message. With opts.raw,
 * returns stdout text unparsed (for pull-discussion).
 */
export async function runEng(
  command: string,
  positional: string[],
  opts: RunOpts = {},
  env: Env = process.env,
  spawn: SpawnFn = defaultSpawn,
): Promise<unknown> {
  const bin = resolveEngBin(env);
  // Raw tools (pull-discussion) output text and do NOT strip a trailing
  // --json flag from their positional args, so we must not append it.
  const argv = opts.raw
    ? [bin, command, ...positional]
    : [bin, command, ...positional, "--json"];
  const childEnv: Env = { ...env };
  if (opts.team) childEnv.ENG_TEAM = opts.team;

  const { stdout, stderr, exitCode } = await spawn(argv, childEnv);

  if (opts.raw && exitCode === 0) return stdout;

  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    throw new Error(
      `eng ${command} produced unparseable output (exit ${exitCode}).\n` +
        `stdout: ${stdout}\nstderr: ${stderr}`,
    );
  }

  if (exitCode !== 0) {
    const err = parsed as { code?: string; error?: string };
    const code = err.code ?? "UNKNOWN";
    const message = err.error ?? "eng command failed";
    throw new Error(`[${code}] ${message}`);
  }

  return parsed;
}
