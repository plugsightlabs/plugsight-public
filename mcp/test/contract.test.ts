// The generated contract (mcp/contract/tools.json) is the source of truth two
// gates consume (docs/spec/03/08): the drift gate that renders the public
// capability table, and the round-trip test. It must contain exactly the 19
// tool names, be deterministic, carry the score_device caveat, and stay in sync
// with the registered tools (a tool added without regenerating fails the build).

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { buildContract, serializeContract } from "../src/contract.ts";

const EXPECTED_19 = [
  "acknowledge_alert",
  "cancel_scan",
  "clear_device_mark",
  "explain_event",
  "flag_device",
  "get_device",
  "get_policy",
  "get_scan",
  "get_status",
  "get_timeline",
  "list_alerts",
  "list_devices",
  "mute_device",
  "restore_quarantine",
  "scan_storage",
  "score_device",
  "set_policy",
  "tail_events",
  "trust_device",
];

test("the contract contains exactly the 19 tool names, sorted", () => {
  const c = buildContract();
  const names = c.tools.map((t) => t.name);
  assert.equal(c.tools.length, 19);
  assert.deepEqual(names, EXPECTED_19); // already sorted
  assert.equal(c.toolCount, 19);
});

test("every contract tool carries its API method, mutating flag, input schema, output", () => {
  const c = buildContract();
  for (const t of c.tools) {
    assert.ok(t.method, `${t.name} declares its API method`);
    assert.equal(typeof t.mutating, "boolean");
    assert.ok(t.inputSchema && typeof t.inputSchema === "object", `${t.name} has an input JSON schema`);
    assert.ok("output" in t, `${t.name} declares an output shape`);
  }
});

test("the serialized contract is deterministic", () => {
  assert.equal(serializeContract(buildContract()), serializeContract(buildContract()));
});

test("the contract embeds the score_device caveat (the drift gate greps for it)", () => {
  const json = serializeContract(buildContract());
  assert.ok(
    json.includes("Behavioral scoring is probabilistic and a patient attacker can evade it."),
    "score_device caveat is present in tools.json",
  );
});

test("the committed contract/tools.json is in sync with the registered tools", () => {
  const path = new URL("../contract/tools.json", import.meta.url);
  const onDisk = fs.readFileSync(path, "utf8");
  assert.equal(
    onDisk,
    serializeContract(buildContract()),
    "mcp/contract/tools.json is stale — run `npm run gen:contract` and commit it",
  );
});
