import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { TOOLS, buildArgs, schemaFor } from "./tools.ts";
import { runEng } from "./eng-runner.ts";

const server = new McpServer({ name: "engleader", version: "0.1.0" });

for (const tool of TOOLS) {
  server.tool(tool.name, tool.description, schemaFor(tool), async (params: any) => {
    try {
      const result = await runEng(
        tool.command,
        buildArgs(tool, params),
        { team: params.team, raw: tool.raw },
      );
      const text = typeof result === "string" ? result : JSON.stringify(result, null, 2);
      return { content: [{ type: "text" as const, text }] };
    } catch (e: any) {
      return {
        isError: true,
        content: [{ type: "text" as const, text: e?.message ?? String(e) }],
      };
    }
  });
}

const transport = new StdioServerTransport();
await server.connect(transport);
