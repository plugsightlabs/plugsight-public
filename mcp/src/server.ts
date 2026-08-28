// The MCP server wiring: register the 19 tools onto an McpServer, each handler
// forwarding to the daemon via the socket client. This is the whole surface —
// no business logic, just registration and forwarding (docs/spec/02: the MCP
// server is deliberately thin).

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { PlugsightClient } from "./client.ts";
import { TOOLS, executeTool } from "./tools.ts";

export const SERVER_NAME = "@plugsight/mcp";
export const SERVER_VERSION = "0.1.0";

/** Build an McpServer with every tool registered against the given daemon
 * client. Connect it to a transport (stdio in production, in-memory in tests). */
export function createServer(plug: PlugsightClient): McpServer {
  const server = new McpServer(
    { name: SERVER_NAME, version: SERVER_VERSION },
    {
      instructions:
        "Plugsight watches USB/HID devices and storage for this Mac. Every capability the menu-bar app has is a tool here. Call get_status first. Mutations are attributed to you in the human's timeline.",
    },
  );

  for (const tool of TOOLS) {
    server.registerTool(
      tool.name,
      {
        description: tool.description,
        inputSchema: tool.input.shape,
        annotations: {
          readOnlyHint: !tool.mutating,
          destructiveHint: tool.mutating,
        },
      },
      async (args: Record<string, unknown>) => {
        return executeTool(plug, tool, args ?? {});
      },
    );
  }

  return server;
}
