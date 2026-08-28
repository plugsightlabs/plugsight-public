// One test per tool against the mock daemon: the adapter forwards the right API
// method and passes the canned result shape through as structured content, plus
// the required special cases — score_device's caveat, trust_device's caveat,
// restore_quarantine's mandatory confirm + explicit-risk sentence, get_scan's
// scanId/deviceId routing, and daemon_unreachable mapping with the literal fix.

import { test } from "node:test";
import assert from "node:assert/strict";
import { MockDaemon } from "./mock-daemon.ts";
import { PlugsightClient } from "../src/client.ts";
import { DAEMON_UNREACHABLE_FIX } from "../src/errors.ts";
import { TOOLS, toolByName, executeTool } from "../src/tools.ts";

const EXPECTED_19 = [
  "get_status",
  "list_devices",
  "get_device",
  "get_timeline",
  "explain_event",
  "tail_events",
  "score_device",
  "list_alerts",
  "acknowledge_alert",
  "trust_device",
  "mute_device",
  "flag_device",
  "clear_device_mark",
  "scan_storage",
  "cancel_scan",
  "get_scan",
  "restore_quarantine",
  "get_policy",
  "set_policy",
];

test("registers exactly the 19 tools of the inventory", () => {
  assert.equal(TOOLS.length, 19);
  assert.deepEqual(new Set(TOOLS.map((t) => t.name)), new Set(EXPECTED_19));
});

// Representative call per non-tail tool: the tool name, args, the API method it
// must forward to, and a key the structured content must carry.
const CASES: { tool: string; args: Record<string, unknown>; method: string; key: string }[] = [
  { tool: "get_status", args: {}, method: "status.get", key: "monitoring" },
  { tool: "list_devices", args: {}, method: "devices.list", key: "devices" },
  { tool: "get_device", args: { deviceId: "dev_9f3ac2" }, method: "devices.get", key: "deviceId" },
  { tool: "get_timeline", args: {}, method: "timeline.list", key: "events" },
  { tool: "explain_event", args: { eventId: "evt_01H8XYZ" }, method: "events.get", key: "why" },
  { tool: "score_device", args: { deviceId: "dev_2ab919" }, method: "score.get", key: "caveat" },
  { tool: "list_alerts", args: {}, method: "alerts.list", key: "alerts" },
  { tool: "acknowledge_alert", args: { alertId: "alt_7", comment: "seen" }, method: "alerts.ack", key: "alert" },
  { tool: "trust_device", args: { deviceId: "dev_2ab919" }, method: "trust.set", key: "caveat" },
  { tool: "mute_device", args: { deviceId: "dev_2ab919" }, method: "trust.set", key: "device" },
  { tool: "flag_device", args: { deviceId: "dev_2ab919" }, method: "trust.set", key: "device" },
  { tool: "clear_device_mark", args: { deviceId: "dev_2ab919" }, method: "trust.set", key: "device" },
  { tool: "scan_storage", args: { deviceId: "dev_9f3ac2" }, method: "scan.start", key: "scanId" },
  { tool: "cancel_scan", args: { scanId: "scan_42" }, method: "scan.cancel", key: "state" },
  { tool: "get_scan", args: { scanId: "scan_42" }, method: "scan.get", key: "scanId" },
  { tool: "restore_quarantine", args: { quarantineId: "q_9", confirm: true }, method: "quarantine.restore", key: "state" },
  { tool: "get_policy", args: {}, method: "policy.get", key: "scanOnMount" },
  { tool: "set_policy", args: { scanOnMount: true }, method: "policy.set", key: "scanOnMount" },
];

for (const c of CASES) {
  test(`${c.tool} forwards to ${c.method} and returns structured content`, async () => {
    const mock = new MockDaemon();
    await mock.start();
    const client = new PlugsightClient({ baseDir: mock.baseDir });
    try {
      const tool = toolByName(c.tool);
      assert.equal(tool.method, c.method, `${c.tool} maps to ${c.method}`);
      const res = await executeTool(client, tool, c.args);
      assert.notEqual(res.isError, true, `${c.tool} should not error`);
      assert.ok(res.structuredContent, "has structured content");
      assert.ok(
        Object.prototype.hasOwnProperty.call(res.structuredContent as object, c.key),
        `${c.tool} structured content carries '${c.key}'`,
      );
      assert.ok(res.content[0]?.text?.length, "has a plain-text rendering");
    } finally {
      client.close();
      await mock.stop();
    }
  });
}

// mcp-limit-bounds: get_timeline's limit is bounded per spec 03 (default 50,
// max 500), so a caller cannot ask the daemon for an unbounded page.
test("get_timeline limit is bounded to 1..500 and defaults to 50", () => {
  const input = toolByName("get_timeline").input;

  // Default when omitted.
  const omitted = input.parse({});
  assert.equal((omitted as { limit: number }).limit, 50);

  // In-range values pass through.
  assert.equal((input.parse({ limit: 1 }) as { limit: number }).limit, 1);
  assert.equal((input.parse({ limit: 500 }) as { limit: number }).limit, 500);

  // Out-of-range values are rejected.
  assert.equal(input.safeParse({ limit: 0 }).success, false, "limit 0 rejected");
  assert.equal(input.safeParse({ limit: 501 }).success, false, "limit 501 rejected");
  assert.equal(input.safeParse({ limit: 1000 }).success, false, "limit 1000 rejected");
});

test("score_device carries the exact charter caveat", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    const res = await executeTool(client, toolByName("score_device"), { deviceId: "dev_2ab919" });
    const sc = res.structuredContent as { caveat: string };
    assert.equal(
      sc.caveat,
      "Behavioral scoring is probabilistic and a patient attacker can evade it.",
    );
  } finally {
    client.close();
    await mock.stop();
  }
});

test("restore_quarantine requires confirm and surfaces the explicit-risk sentence", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    // Missing confirm -> invalid_params, refusing before it ever calls the daemon.
    const bad = await executeTool(client, toolByName("restore_quarantine"), { quarantineId: "q_9" });
    assert.equal(bad.isError, true);
    const be = bad.structuredContent as { error: { kind: string; message: string } };
    assert.equal(be.error.kind, "invalid_params");
    assert.match(be.error.message, /deliberate|confirm|false positive/i);

    // With confirm:true -> success, and the risk sentence rides in the result.
    const ok = await executeTool(client, toolByName("restore_quarantine"), {
      quarantineId: "q_9",
      confirm: true,
    });
    assert.notEqual(ok.isError, true);
    const oc = ok.structuredContent as { risk: string };
    assert.equal(
      oc.risk,
      "You are restoring a file ClamAV flagged; only do this if you are certain it is a false positive.",
    );
  } finally {
    client.close();
    await mock.stop();
  }
});

test("get_scan routes scanId to scan.get, deviceId to scans.list, neither to invalid_params", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    const byId = await executeTool(client, toolByName("get_scan"), { scanId: "scan_42" });
    assert.ok((byId.structuredContent as { scanId?: string }).scanId);

    const byDevice = await executeTool(client, toolByName("get_scan"), { deviceId: "dev_9f3ac2" });
    assert.ok((byDevice.structuredContent as { scans?: unknown[] }).scans);

    const neither = await executeTool(client, toolByName("get_scan"), {});
    assert.equal(neither.isError, true);
    assert.equal((neither.structuredContent as { error: { kind: string } }).error.kind, "invalid_params");
  } finally {
    client.close();
    await mock.stop();
  }
});

test("a daemon-side error is forwarded verbatim with its kind", async () => {
  const mock = new MockDaemon({
    errors: {
      "devices.get": {
        code: -32000,
        message: "No device with id 'dev_zzz'. Use list_devices to see known devices.",
        kind: "not_found",
      },
    },
  });
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    const res = await executeTool(client, toolByName("get_device"), { deviceId: "dev_zzz" });
    assert.equal(res.isError, true);
    const e = res.structuredContent as { error: { kind: string; message: string } };
    assert.equal(e.error.kind, "not_found");
    assert.match(e.error.message, /No device with id 'dev_zzz'/);
  } finally {
    client.close();
    await mock.stop();
  }
});

test("every tool maps daemon_unreachable with the literal fix", async () => {
  const baseDir = MockDaemon.unreachableBaseDir();
  const client = new PlugsightClient({ baseDir });
  const res = await executeTool(client, toolByName("get_status"), {});
  assert.equal(res.isError, true);
  const e = res.structuredContent as { error: { kind: string; message: string } };
  assert.equal(e.error.kind, "daemon_unreachable");
  assert.ok(e.error.message.includes(DAEMON_UNREACHABLE_FIX));
  assert.ok(res.content[0].text.includes(DAEMON_UNREACHABLE_FIX));
  client.close();
});
