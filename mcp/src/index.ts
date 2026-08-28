#!/usr/bin/env node
// Plugsight MCP server entry point (`npx @plugsight/mcp`).
//
// stdio transport on one side, the daemon's Unix socket on the other. The
// socket path and token are read from the well-known state directory
// (docs/spec/02) on the first tool call, so startup is zero-config and a call
// made while the daemon is down returns a structured daemon_unreachable rather
// than the process failing. The connecting agent's name is captured from the
// MCP initialize handshake so its mutations are attributed in the timeline.

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { PlugsightClient } from "./client.ts";
import { createServer } from "./server.ts";

export async function main(): Promise<void> {
  const plug = new PlugsightClient({ clientInfo: { name: "plugsight-mcp", kind: "mcp" } });
  const server = createServer(plug);

  // Attribute mutations to the actual MCP client (e.g. "mcp:claude-code").
  server.server.oninitialized = () => {
    const info = server.server.getClientVersion();
    if (info?.name) plug.setClientName(info.name);
  };

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((err) => {
    process.stderr.write(`@plugsight/mcp failed to start: ${String(err)}\n`);
    process.exit(1);
  });
}
