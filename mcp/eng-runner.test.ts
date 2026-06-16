import { test, expect } from "bun:test";
import { resolveEngBin, runEng } from "./eng-runner.ts";

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

// A fake spawn that records the call and returns canned output.
function fakeSpawn(result: { stdout: string; stderr: string; exitCode: number }) {
  const calls: { argv: string[]; env: Record<string, string | undefined> }[] = [];
  const spawn = (argv: string[], env: Record<string, string | undefined>) => {
    calls.push({ argv, env });
    return Promise.resolve(result);
  };
  return { spawn, calls };
}

test("runEng builds argv: eng <command> <...positional> --json", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn, calls } = fakeSpawn({
    stdout: '{"metric":"lead-time","data":{}}',
    stderr: "",
    exitCode: 0,
  });
  await runEng("lead-time", ["acme/widget", "30"], {}, env, spawn);
  expect(calls[0]!.argv).toEqual(["/bin/eng", "lead-time", "acme/widget", "30", "--json"]);
});

test("runEng passes team as ENG_TEAM in the child env", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn, calls } = fakeSpawn({ stdout: "{}", stderr: "", exitCode: 0 });
  await runEng("lead-time", ["acme/widget"], { team: "frontend" }, env, spawn);
  expect(calls[0]!.env.ENG_TEAM).toBe("frontend");
});

test("runEng returns the parsed envelope on exit 0", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn } = fakeSpawn({
    stdout: '{"metric":"lead-time","data":{"count":3}}',
    stderr: "",
    exitCode: 0,
  });
  const out = await runEng("lead-time", ["acme/widget"], {}, env, spawn);
  expect(out).toEqual({ metric: "lead-time", data: { count: 3 } });
});

test("runEng throws the {error,code} object on non-zero exit", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn } = fakeSpawn({
    stdout: '{"error":"gh is not authenticated","code":"AUTH"}',
    stderr: "",
    exitCode: 1,
  });
  await expect(runEng("lead-time", ["acme/widget"], {}, env, spawn)).rejects.toThrow(
    /AUTH.*gh is not authenticated/s
  );
});

test("runEng wraps unparseable stdout in a debuggable error", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn } = fakeSpawn({ stdout: "not json at all", stderr: "boom", exitCode: 0 });
  await expect(runEng("lead-time", ["acme/widget"], {}, env, spawn)).rejects.toThrow(
    /not json at all|boom/s
  );
});

test("runEng with raw:true returns stdout text unparsed", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn } = fakeSpawn({ stdout: "PR #42 discussion...", stderr: "", exitCode: 0 });
  const out = await runEng("pull-discussion", ["acme/widget", "42"], { raw: true }, env, spawn);
  expect(out).toBe("PR #42 discussion...");
});

test("runEng with raw:true does NOT append --json", async () => {
  const env = { ENG_BIN: "/bin/eng" };
  const { spawn, calls } = fakeSpawn({ stdout: "text", stderr: "", exitCode: 0 });
  await runEng("pull-discussion", ["acme/widget", "42"], { raw: true }, env, spawn);
  expect(calls[0]!.argv).toEqual(["/bin/eng", "pull-discussion", "acme/widget", "42"]);
});
