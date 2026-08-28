// PlugsightError.fromRpcError (docs/spec/02): the daemon's stable `kind` rides
// in `data.kind`. A missing or unrecognized kind must fall back to the neutral
// `unknown`, never to a meaningful branch like `conflict` that agents act on.

import { test } from "node:test";
import assert from "node:assert/strict";
import { PlugsightError } from "../src/errors.ts";

test("fromRpcError keeps a recognized daemon kind", () => {
  const err = PlugsightError.fromRpcError({
    message: "No such device.",
    data: { kind: "not_found", deviceId: "dev_x" },
  });
  assert.equal(err.kind, "not_found");
  assert.equal(err.message, "No such device.");
  // Non-kind data rides alongside, with `kind` stripped out.
  assert.deepEqual(err.data, { deviceId: "dev_x" });
});

test("fromRpcError falls back to 'unknown' when data.kind is absent", () => {
  const err = PlugsightError.fromRpcError({ message: "Something went wrong.", data: {} });
  // Must NOT be 'conflict' (agents branch on that as a meaningful state).
  assert.equal(err.kind, "unknown");
});

test("fromRpcError falls back to 'unknown' when there is no data at all", () => {
  const err = PlugsightError.fromRpcError({ message: "Bare error." });
  assert.equal(err.kind, "unknown");
});

test("fromRpcError rejects an arbitrary/unrecognized kind string", () => {
  const err = PlugsightError.fromRpcError({
    message: "Weird.",
    data: { kind: "totally_made_up" },
  });
  // An unvalidated cast would have leaked 'totally_made_up' through as an
  // ErrorKind; validation forces it to the neutral fallback.
  assert.equal(err.kind, "unknown");
});
