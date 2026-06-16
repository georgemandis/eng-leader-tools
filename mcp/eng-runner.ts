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
