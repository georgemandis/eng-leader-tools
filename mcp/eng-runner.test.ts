import { test, expect } from "bun:test";
import { resolveEngBin } from "./eng-runner.ts";

test("resolveEngBin prefers ENG_BIN env var", () => {
  const bin = resolveEngBin({ ENG_BIN: "/custom/path/eng", PATH: "/usr/bin" });
  expect(bin).toBe("/custom/path/eng");
});

test("resolveEngBin returns 'eng' when on PATH and no override", () => {
  // findOnPath is injected so the test doesn't depend on the real PATH
  const bin = resolveEngBin({ PATH: "/usr/bin" }, () => "/usr/bin/eng");
  expect(bin).toBe("/usr/bin/eng");
});

test("resolveEngBin throws an actionable error when eng is missing", () => {
  expect(() => resolveEngBin({ PATH: "/usr/bin" }, () => null)).toThrow(
    /brew install eng-leader-tools.*scoop install eng-leader-tools/s
  );
});
