// Client <-> daemon handshake and connection-error mapping.
//
// Covers: auth.hello returns the version picture; a normal call passes through;
// an unreachable daemon maps to kind:"daemon_unreachable" with the LITERAL fix
// text (docs/spec/03); a stale/unknown apiVersion is refused.

import { test } from "node:test";
import assert from "node:assert/strict";
import { MockDaemon } from "./mock-daemon.ts";
import { PlugsightClient } from "../src/client.ts";
import { PlugsightError, DAEMON_UNREACHABLE_FIX } from "../src/errors.ts";

test("connect performs auth.hello and returns the version picture", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir, clientInfo: { name: "claude-code", kind: "mcp" } });
  try {
    const hello = await client.connect();
    assert.equal(hello.apiVersion, 1);
    assert.equal(hello.daemonVersion, "1.0.0");
    assert.equal(hello.capabilities.clamav, true);
  } finally {
    client.close();
    await mock.stop();
  }
});

test("a normal call passes the canned result through", async () => {
  const mock = new MockDaemon();
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    const status = (await client.call("status.get", {})) as { monitoring: string; devicesPresent: number };
    assert.equal(status.monitoring, "degraded");
    assert.equal(status.devicesPresent, 4);
  } finally {
    client.close();
    await mock.stop();
  }
});

test("an unreachable daemon maps to daemon_unreachable with the literal fix", async () => {
  const baseDir = MockDaemon.unreachableBaseDir();
  const client = new PlugsightClient({ baseDir });
  await assert.rejects(
    () => client.connect(),
    (err: unknown) => {
      assert.ok(err instanceof PlugsightError);
      assert.equal(err.kind, "daemon_unreachable");
      assert.equal(
        DAEMON_UNREACHABLE_FIX,
        "Start Plugsight from /Applications, or run its Start monitoring command",
      );
      assert.ok(err.message.includes(DAEMON_UNREACHABLE_FIX), "message carries the literal fix");
      return true;
    },
  );
  client.close();
});

test("an unknown apiVersion is refused", async () => {
  const mock = new MockDaemon({ apiVersion: 999 });
  await mock.start();
  const client = new PlugsightClient({ baseDir: mock.baseDir });
  try {
    await assert.rejects(
      () => client.connect(),
      (err: unknown) => {
        assert.ok(err instanceof PlugsightError);
        assert.equal(err.kind, "unsupported_api_version");
        assert.ok(err.message.includes("999"), "message names the offending version");
        return true;
      },
    );
  } finally {
    client.close();
    await mock.stop();
  }
});
