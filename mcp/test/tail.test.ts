// tail_events long-poll (docs/spec/03): return as soon as an event arrives,
// else an empty list and a fresh cursor when waitSeconds elapses.

import { test } from "node:test";
import assert from "node:assert/strict";
import { MockDaemon } from "./mock-daemon.ts";
import { CANNED_EVENT_APPENDED } from "./canned.ts";
import { PlugsightClient } from "../src/client.ts";
import { toolByName, executeTool } from "../src/tools.ts";

test("tail_events returns early when an event arrives", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    const started = Date.now();
    const pending = executeTool(client, toolByName("tail_events"), { waitSeconds: 30 });
    // Give the subscription a moment to register, then push one live event.
    setTimeout(() => mock.pushEvent(CANNED_EVENT_APPENDED), 60);
    const res = await pending;
    const elapsed = Date.now() - started;

    assert.notEqual(res.isError, true);
    const sc = res.structuredContent as { events: { eventId: string }[]; nextCursor: string | null };
    assert.equal(sc.events.length, 1);
    assert.equal(sc.events[0].eventId, "evt_live1");
    assert.equal(sc.nextCursor, "evt_live1");
    assert.ok(elapsed < 5000, "returned early, well under waitSeconds");
  } finally {
    client.close();
    await mock.stop();
  }
});

test("tail_events returns an empty list and a fresh cursor at timeout", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    const res = await executeTool(client, toolByName("tail_events"), {
      waitSeconds: 1,
      afterCursor: "evt_prev",
    });
    assert.notEqual(res.isError, true);
    const sc = res.structuredContent as { events: unknown[]; nextCursor: string | null };
    assert.equal(sc.events.length, 0);
    assert.equal(sc.nextCursor, "evt_prev");
  } finally {
    client.close();
    await mock.stop();
  }
});

// mcp-tail-leak: tail_events must release the daemon-side subscription with
// events.untail on completion, else subscriptions leak unbounded.
test("tail_events releases its subscription with events.untail (early-return path)", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    const pending = executeTool(client, toolByName("tail_events"), { waitSeconds: 30 });
    setTimeout(() => mock.pushEvent(CANNED_EVENT_APPENDED), 60);
    await pending;

    const tail = mock.calls.find((c) => c.method === "events.tail");
    const untail = mock.calls.find((c) => c.method === "events.untail");
    assert.ok(tail, "events.tail was called");
    assert.ok(untail, "events.untail was called to release the subscription");
    // The subscription id the daemon returned (canned sub_1) must be the one
    // passed to untail, so the RIGHT subscription is torn down.
    assert.deepEqual(untail!.params, { subscriptionId: "sub_1" });
  } finally {
    client.close();
    await mock.stop();
  }
});

test("tail_events releases its subscription with events.untail (timeout path)", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    await executeTool(client, toolByName("tail_events"), { waitSeconds: 1 });
    const untail = mock.calls.find((c) => c.method === "events.untail");
    assert.ok(untail, "events.untail was called even when the poll timed out");
    assert.deepEqual(untail!.params, { subscriptionId: "sub_1" });
  } finally {
    client.close();
    await mock.stop();
  }
});

// mcp-tail-filter: the client fans every event.appended out to every handler.
// tail_events must re-check each event against its OWN filter and keep waiting
// on a non-match, rather than resolving on the first notification.
test("tail_events ignores a fanned-out event that does not match its filter", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    const started = Date.now();
    // Filter to one device; a concurrent tail's event for ANOTHER device is
    // fanned to us too, and must NOT wake us.
    const pending = executeTool(client, toolByName("tail_events"), {
      waitSeconds: 2,
      filter: { deviceId: "dev_wanted" },
    });
    setTimeout(() => mock.pushEvent({ ...CANNED_EVENT_APPENDED, eventId: "evt_other", deviceId: "dev_other" }), 40);
    const res = await pending;
    const elapsed = Date.now() - started;

    const sc = res.structuredContent as { events: { eventId: string }[]; nextCursor: string | null };
    assert.equal(sc.events.length, 0, "non-matching event was ignored, so the poll timed out empty");
    assert.ok(elapsed >= 1900, "held until timeout rather than resolving on the non-matching event");
  } finally {
    client.close();
    await mock.stop();
  }
});

test("tail_events resolves on an event that matches its filter", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    const pending = executeTool(client, toolByName("tail_events"), {
      waitSeconds: 30,
      filter: { deviceId: "dev_wanted" },
    });
    // First a non-matching event (ignored), then a matching one (wakes us).
    setTimeout(() => mock.pushEvent({ ...CANNED_EVENT_APPENDED, eventId: "evt_other", deviceId: "dev_other" }), 30);
    setTimeout(() => mock.pushEvent({ ...CANNED_EVENT_APPENDED, eventId: "evt_wanted", deviceId: "dev_wanted" }), 80);
    const res = await pending;

    const sc = res.structuredContent as { events: { eventId: string }[]; nextCursor: string | null };
    assert.equal(sc.events.length, 1);
    assert.equal(sc.events[0].eventId, "evt_wanted");
    assert.equal(sc.nextCursor, "evt_wanted");
  } finally {
    client.close();
    await mock.stop();
  }
});
