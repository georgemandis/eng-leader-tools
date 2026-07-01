import { test, expect } from "bun:test";
import { TOOLS, buildArgs, schemaFor } from "./tools.ts";

test("there are 16 tools", () => {
  expect(TOOLS.length).toBe(16);
});

test("every tool name is eng_ prefixed and unique", () => {
  const names = TOOLS.map((t) => t.name);
  for (const n of names) expect(n).toMatch(/^eng_[a-z_]+$/);
  expect(new Set(names).size).toBe(names.length);
});

test("exactly 7 tools are team-aware", () => {
  expect(TOOLS.filter((t) => t.teamAware).length).toBe(7);
});

test("buildArgs puts repo first, then the numeric param when present", () => {
  const tool = TOOLS.find((t) => t.name === "eng_lead_time")!;
  expect(buildArgs(tool, { repo: "acme/widget", window_days: 30 })).toEqual([
    "acme/widget",
    "30",
  ]);
});

test("buildArgs omits an absent optional numeric param", () => {
  const tool = TOOLS.find((t) => t.name === "eng_lead_time")!;
  expect(buildArgs(tool, { repo: "acme/widget" })).toEqual(["acme/widget"]);
});

test("eng_code_churn supports a second numeric param (min_changes)", () => {
  const tool = TOOLS.find((t) => t.name === "eng_code_churn")!;
  expect(buildArgs(tool, { repo: "acme/widget", window_days: 30, min_changes: 3 })).toEqual([
    "acme/widget",
    "30",
    "3",
  ]);
});

test("eng_pull_discussion requires pr_number and is raw", () => {
  const tool = TOOLS.find((t) => t.name === "eng_pull_discussion")!;
  expect(tool.raw).toBe(true);
  expect(buildArgs(tool, { repo: "acme/widget", pr_number: 42 })).toEqual([
    "acme/widget",
    "42",
  ]);
});

test("buildArgs admits a 0 value for an optional numeric param", () => {
  const tool = TOOLS.find((t) => t.name === "eng_code_churn")!;
  expect(buildArgs(tool, { repo: "acme/widget", window_days: 0 })).toEqual([
    "acme/widget",
    "0",
  ]);
});

test("buildArgs throws when a later positional is set but an earlier one is omitted", () => {
  const tool = TOOLS.find((t) => t.name === "eng_code_churn")!;
  expect(() => buildArgs(tool, { repo: "acme/widget", min_changes: 3 })).toThrow(
    /min_changes.*earlier positional/s
  );
});

test("buildArgs throws when repo is missing", () => {
  const tool = TOOLS.find((t) => t.name === "eng_lead_time")!;
  expect(() => buildArgs(tool, {})).toThrow(/repo/);
});

test("local tools omit repo and never require it (directory is cwd, not an arg)", () => {
  const tool = TOOLS.find((t) => t.name === "eng_hotspots")!;
  expect(tool.local).toBe(true);
  // directory is NOT a positional — it becomes the child cwd in index.ts.
  expect(buildArgs(tool, { directory: "/some/repo" })).toEqual([]);
  expect(buildArgs(tool, { directory: "/some/repo", window_days: 90, min_changes: 5 })).toEqual([
    "90",
    "5",
  ]);
});

test("local tools accept an optional path scope as a trailing positional", () => {
  const tool = TOOLS.find((t) => t.name === "eng_todo_debt")!;
  expect(tool.local).toBe(true);
  expect(buildArgs(tool, {})).toEqual([]);
  expect(buildArgs(tool, { path: "src/" })).toEqual(["src/"]);
});

test("schemaFor exposes directory (not repo) for local tools", () => {
  const tool = TOOLS.find((t) => t.name === "eng_test_ratio")!;
  const shape = schemaFor(tool);
  expect(shape.directory).toBeDefined();
  expect(shape.repo).toBeUndefined();
});
