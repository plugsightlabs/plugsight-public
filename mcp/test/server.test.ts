// End-to-end wiring: the MCP server registers all 19 tools and, driven through
// a real MCP client over an in-memory transport, answers a tool call by
// forwarding to the (mock) daemon and returning structured content.

import { test } from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { MockDaemon } from "./mock-daemon.ts";
import { PlugsightClient } from "../src/client.ts";
import { createServer } from "../src/server.ts";

test("the server exposes exactly 19 tools and answers a call through MCP", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const plug = new PlugsightClient({ baseDir: mock.baseDir, clientInfo: { name: "claude-code", kind: "mcp" } });
  const server = createServer(plug);

  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "test-agent", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

  try {
    const list = await client.listTools();
    assert.equal(list.tools.length, 19);
    assert.ok(list.tools.some((t) => t.name === "get_status"));
    assert.ok(list.tools.some((t) => t.name === "restore_quarantine"));

    const res = (await client.callTool({ name: "get_status", arguments: {} })) as {
      structuredContent?: { monitoring?: string };
      isError?: boolean;
    };
    assert.notEqual(res.isError, true);
    assert.equal(res.structuredContent?.monitoring, "degraded");
  } finally {
    await client.close();
    await server.close();
    plug.close();
    await mock.stop();
  }
});
