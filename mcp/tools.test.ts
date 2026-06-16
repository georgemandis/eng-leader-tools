import { test, expect } from "bun:test";
import { TOOLS, buildArgs } from "./tools.ts";

test("there are 13 tools", () => {
  expect(TOOLS.length).toBe(13);
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
