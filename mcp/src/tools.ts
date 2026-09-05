// The 19 tools (docs/spec/03, owner ruling D6).
//
// Each tool is a thin forward to exactly one local API method (docs/spec/02),
// with zod input schemas transcribed from 03. Handlers reshape the tool input
// into the method's params, pass the daemon's result through untouched as
// structured content, and add a short plain-text rendering of the same facts.
// No business logic lives here; the daemon owns every decision. The two
// client-side guards that DO live here (restore_quarantine's confirm and
// get_scan's routing) are input plumbing, not policy.

import { z } from "zod";
import type { PlugsightClient } from "./client.ts";
import { PlugsightError, toToolError } from "./errors.ts";

// MARK: - Result shape

export interface ToolResult {
  content: { type: "text"; text: string }[];
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
  // The MCP SDK's CallToolResult carries an open index signature; mirror it so a
  // ToolResult is accepted directly as a tool handler's return.
  [key: string]: unknown;
}

/** A successful tool result: structured content plus its plain-text rendering. */
function ok(structured: Record<string, unknown>, text: string): ToolResult {
  return { content: [{ type: "text", text }], structuredContent: structured };
}

/** Drop keys whose value is undefined, so we never send `{"present":null}` for
 * an omitted filter field. */
function compact<T extends Record<string, unknown>>(obj: T): Partial<T> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) if (v !== undefined) out[k] = v;
  return out as Partial<T>;
}

/** Does a live event.appended payload match a timeline filter? Mirrors the
 * daemon's timeline query (EventStore+API, docs/spec/02): deviceId and severity
 * are exact, kinds is membership, since/until are an inclusive ISO range. Used
 * by tail_events to re-check each fanned-out notification against its OWN
 * filter, so a concurrent tail with a different filter cannot wake it. */
function eventMatchesFilter(
  event: Record<string, unknown>,
  filter?: Record<string, unknown>,
): boolean {
  if (!filter) return true;
  const deviceId = filter.deviceId as string | undefined;
  if (deviceId !== undefined && event.deviceId !== deviceId) return false;
  const kinds = filter.kinds as string[] | undefined;
  if (kinds !== undefined && kinds.length > 0 && !kinds.includes(event.kind as string)) return false;
  const sev = filter.severity as string | undefined;
  if (sev !== undefined && event.severity !== sev) return false;
  const at = event.at as string | undefined;
  const since = filter.since as string | undefined;
  if (since !== undefined && !(typeof at === "string" && at >= since)) return false;
  const until = filter.until as string | undefined;
  if (until !== undefined && !(typeof at === "string" && at <= until)) return false;
  return true;
}

// MARK: - Charter copy (load-bearing literals)

const SCORE_CAVEAT = "Behavioral scoring is probabilistic and a patient attacker can evade it.";
const RESTORE_RISK =
  "You are restoring a file ClamAV flagged; only do this if you are certain it is a false positive.";

// MARK: - Shared schema fragments (input)

const trustTier = z.enum(["trusted", "muted", "flagged", "none"]);
const severity = z.enum(["info", "notice", "warning", "critical"]);
const timelineFilter = z
  .object({
    deviceId: z.string(),
    kinds: z.array(z.string()),
    severity,
    since: z.string(),
    until: z.string(),
  })
  .partial();

// MARK: - Shared schema fragments (OUTPUT — the canonical wire shapes, 03/06)
//
// These are the DECLARED output schemas the round-trip gate validates the REAL
// daemon's responses against. They REQUIRE every field the UI/agent consumes, so
// a daemon field rename fails the round-trip. Extra daemon fields are stripped by
// zod's default (non-strict) parse — the daemon may emit more, never less.

const oSuggestedAction = z.object({ tool: z.string(), label: z.string() });
const oTimelineEvent = z.object({
  eventId: z.string(),
  at: z.string(),
  kind: z.string(),
  severity: z.string(),
  deviceId: z.string().nullish(),
  summary: z.string(),
  actor: z.string(),
});
const oScoreBrief = z.object({ value: z.number(), confidence: z.string() });
const oInterfaceRow = z.object({
  seq: z.number(),
  class: z.number(),
  subclass: z.number(),
  protocol: z.number(),
  role: z.string(),
});
const oTrustHistory = z.object({
  tier: z.string(),
  actor: z.string(),
  at: z.string(),
  note: z.string().nullish(),
});
const oTopology = z.object({ port: z.string(), hubPath: z.array(z.string()) });
// The derived per-device verdict (docs/spec/04, "The verdict model"): one
// status word + plain-language reasons ordered most severe first, each with a
// stable id and exactly ONE recommended action. Identical to the GUI
// derivation (computed once in the daemon's core). `action` stays an open
// string so a newer daemon's vocabulary never breaks an older client; today's
// values: scanAgain, installScanner, grantInputMonitoring, restartDaemon,
// reviewQuarantine, reviewAlerts, updateDefinitions, unplug, none.
const oSafetyReason = z.object({
  id: z.string(),
  sentence: z.string(),
  action: z.string(),
});
const oSafetyStatus = z.object({
  // grey means "not checked" and is never rendered as danger (Honesty Charter).
  status: z.enum(["green", "yellow", "red", "grey"]),
  reasons: z.array(oSafetyReason),
});
const oDeviceRecord = z.object({
  deviceId: z.string(),
  name: z.string(),
  present: z.boolean(),
  firstSeen: z.string(),
  lastSeen: z.string(),
  vidPid: z.string(),
  serial: z.string().nullish(),
  trust: z.string(),
  interfaces: z.array(oInterfaceRow),
  trustHistory: z.array(oTrustHistory),
  topology: oTopology.nullish(),
  isStorage: z.boolean(),
  safetyStatus: oSafetyStatus,
});
const oDeviceSummary = z.object({
  deviceId: z.string(),
  name: z.string(),
  present: z.boolean(),
  firstSeen: z.string(),
  lastSeen: z.string(),
  vidPid: z.string(),
  serial: z.string().nullish(),
  interfaceClasses: z.array(z.string()),
  trust: z.string(),
  score: oScoreBrief.nullish(),
  activeAlerts: z.number(),
  safetyStatus: oSafetyStatus,
});
const oAlert = z.object({
  alertId: z.string(),
  deviceId: z.string().nullish(),
  deviceName: z.string(),
  rule: z.string(),
  severity: z.string(),
  state: z.string(),
  at: z.string(),
  summary: z.string(),
  why: z.string(),
  suggestedActions: z.array(oSuggestedAction),
});
const oScoreSignal = z.object({
  id: z.string(),
  observed: z.string(),
  verdict: z.string(),
  weight: z.number(),
});
const oScore = z.object({
  // Null-not-zero (04): a number only when the sensor is on AND data exists.
  // The daemon omits score/confidence entirely when there is no number (Swift
  // omits nil optionals), so they are nullish (absent OR null), never a zero.
  score: z.number().nullish(),
  confidence: z.string().nullish(),
  signals: z.array(oScoreSignal),
  explanation: z.string().nullish(),
  caveat: z.literal(SCORE_CAVEAT),
  sensorAvailable: z.boolean(),
});
const oScanVerdict = z.object({
  filePath: z.string(),
  verdict: z.string(),
  signature: z.string().nullish(),
});
const oQuarantineRecord = z.object({
  quarantineId: z.string(),
  filePath: z.string(),
  signature: z.string(),
  restored: z.boolean(),
  containment: z.string(),
});
const oScan = z.object({
  scanId: z.string(),
  deviceId: z.string().nullish(),
  volumePath: z.string().nullish(),
  engine: z.string().nullish(),
  state: z.string(),
  progress: z.number().nullish(),
  startedAt: z.string(),
  verdicts: z.array(oScanVerdict),
  quarantine: z.array(oQuarantineRecord),
  reason: z.string().nullish(),
});
const oScanSummary = z.object({
  scanId: z.string(),
  deviceId: z.string().nullish(),
  state: z.string(),
  engine: z.string().nullish(),
  startedAt: z.string(),
  finishedAt: z.string().nullish(),
  filesScanned: z.number(),
});
const oPolicy = z.object({
  scanOnMount: z.boolean(),
  quarantine: z.boolean(),
  holdUntilScanned: z.boolean(),
  scanTimeoutMinutes: z.number(),
  clamdSocketPath: z.string().nullish(),
  definitionsWarnDays: z.number(),
  retentionDays: z.number(),
  // The two notification keys (04, D-notify): notify on yellow/red verdicts
  // (default on), and additionally on every first attach (default off).
  notifyUnsafe: z.boolean(),
  notifyNewDevice: z.boolean(),
  // RETIRED: still served for old readers; writes are rejected by the daemon
  // with an error naming notifyUnsafe/notifyNewDevice.
  notificationThreshold: z.string(),
});
const oStatus = z.object({
  monitoring: z.string(),
  daemonVersion: z.string(),
  permissions: z.object({
    inputMonitoring: z.boolean(),
    // "active" | "restart_required" | "off": whether the typing-rhythm sensor
    // is actually collecting. A grant made while the daemon runs flips
    // inputMonitoring to true immediately, but the sensor opens at daemon
    // start, so it reports restart_required until the daemon restarts.
    inputMonitoringSensor: z.string().nullish(),
    esExtension: z.string(),
  }),
  scanner: z.object({
    available: z.boolean(),
    engine: z.string().nullish(),
    definitionsAgeDays: z.number().nullish(),
  }),
  devicesPresent: z.number(),
  activeAlerts: z.number(),
  monitoringGaps: z.array(z.object({ from: z.string(), to: z.string() })),
});
const oTimeline = z.object({ events: z.array(oTimelineEvent), nextCursor: z.string().nullish() });

// MARK: - Tool definition

export interface ToolDef {
  name: string;
  /** The single API method this tool forwards to (03's inventory column). */
  method: string;
  mutating: boolean;
  description: string;
  input: z.ZodObject<z.ZodRawShape>;
  /** Declared zod OUTPUT schema (the canonical wire shape, docs/spec/03). The
   * generated contract serializes it, and the round-trip gate validates the REAL
   * daemon's response against it, so daemon/UI/contract can no longer drift. */
  outputSchema: z.ZodTypeAny;
  handler: (client: PlugsightClient, args: Record<string, unknown>) => Promise<ToolResult>;
}

// A trust tier is set by four differently-named tools sharing one API method.
function trustTool(name: string, tier: "trusted" | "muted" | "flagged" | "none", verb: string): ToolDef {
  return {
    name,
    method: "trust.set",
    mutating: true,
    description: `${verb} (trust.set tier "${tier}"). Returns the updated device, the appended timeline event, and the forgeability caveat.`,
    input: z.object({ deviceId: z.string(), note: z.string().optional() }),
    outputSchema: z.object({ device: oDeviceRecord, event: oTimelineEvent, caveat: z.string() }),
    handler: async (client, args) => {
      const r = (await client.call("trust.set", {
        deviceId: args.deviceId,
        tier,
        note: args.note,
      })) as { event?: { summary?: string }; caveat?: string };
      const summary = r.event?.summary ?? `Trust set to ${tier}.`;
      return ok(r, `${summary} ${r.caveat ?? ""}`.trim());
    },
  };
}

export const TOOLS: ToolDef[] = [
  {
    name: "get_status",
    method: "status.get",
    mutating: false,
    description:
      "The daemon health picture: monitoring state, permissions, scanner, and counts. Read this before trusting any other answer.",
    input: z.object({}),
    outputSchema: oStatus,
    handler: async (client) => {
      const s = (await client.call("status.get", {})) as {
        monitoring: string;
        devicesPresent: number;
        activeAlerts: number;
        scanner: { available: boolean };
      };
      return ok(
        s,
        `Monitoring ${s.monitoring}. ${s.devicesPresent} device(s) present, ${s.activeAlerts} active alert(s). Scanner ${s.scanner.available ? "available" : "unavailable"}.`,
      );
    },
  },
  {
    name: "list_devices",
    method: "devices.list",
    mutating: false,
    description:
      "List present and historical devices, each with a summary, trust tier, score, and its derived safetyStatus (green/yellow/red/grey + reasons, one recommended action per reason).",
    input: z.object({
      present: z.boolean().optional(),
      trust: trustTier.optional(),
      class: z.string().optional(),
      limit: z.number().int().optional(),
      cursor: z.string().optional(),
    }),
    outputSchema: z.object({ devices: z.array(oDeviceSummary), nextCursor: z.string().nullish() }),
    handler: async (client, args) => {
      const filter = compact({ present: args.present, trust: args.trust, class: args.class });
      const r = (await client.call("devices.list", compact({ filter: Object.keys(filter).length ? filter : undefined, limit: args.limit, cursor: args.cursor }))) as {
        devices: unknown[];
      };
      return ok(r, `${r.devices.length} device(s).`);
    },
  },
  {
    name: "get_device",
    method: "devices.get",
    mutating: false,
    description:
      "The full record for one device: interfaces, trust history, score breakdown, counts, and the derived safetyStatus (status word + reasons + one recommended action each).",
    input: z.object({ deviceId: z.string() }),
    outputSchema: oDeviceRecord,
    handler: async (client, args) => {
      const r = (await client.call("devices.get", { deviceId: args.deviceId })) as {
        name?: string;
        trust?: string;
      };
      return ok(r, `${r.name ?? args.deviceId} — trust ${r.trust ?? "unknown"}.`);
    },
  },
  {
    name: "get_timeline",
    method: "timeline.list",
    mutating: false,
    description: "Events newest first, each with a one-sentence plain-language summary.",
    input: z.object({
      deviceId: z.string().optional(),
      kinds: z.array(z.string()).optional(),
      severity: severity.optional(),
      since: z.string().optional(),
      until: z.string().optional(),
      // Spec 03: default 50, max 500. Bound it so a caller cannot ask the daemon
      // for an unbounded page.
      limit: z.number().int().min(1).max(500).default(50),
      cursor: z.string().optional(),
    }),
    outputSchema: oTimeline,
    handler: async (client, args) => {
      const filter = compact({
        deviceId: args.deviceId,
        kinds: args.kinds,
        severity: args.severity,
        since: args.since,
        until: args.until,
      });
      const r = (await client.call("timeline.list", compact({ filter: Object.keys(filter).length ? filter : undefined, limit: args.limit, cursor: args.cursor }))) as {
        events: unknown[];
      };
      return ok(r, `${r.events.length} event(s).`);
    },
  },
  {
    name: "explain_event",
    method: "events.get",
    mutating: false,
    description:
      "One event with its full explanation: detail payload, why, context, and suggested next actions (each naming its tool).",
    input: z.object({ eventId: z.string() }),
    outputSchema: z.object({
      event: oTimelineEvent,
      why: z.string(),
      context: z.object({ detail: z.unknown() }).passthrough(),
      suggestedActions: z.array(oSuggestedAction),
    }),
    handler: async (client, args) => {
      const r = (await client.call("events.get", { eventId: args.eventId })) as {
        event?: { summary?: string };
        why?: string;
      };
      return ok(r, `${r.event?.summary ?? args.eventId}${r.why ? ` Why: ${r.why}` : ""}`);
    },
  },
  {
    name: "tail_events",
    method: "events.tail",
    mutating: false,
    description:
      "Long-poll for the NEXT live event. Subscribes, then holds up to waitSeconds (default 25, max 55), returning as soon as a matching event arrives, else an empty list. Live-only and best-effort: it reports events that occur AFTER this call registers its subscription; it does NOT replay historical events from before then. Loop on it, passing the returned nextCursor back as afterCursor, to keep watching live.",
    input: z.object({
      filter: timelineFilter.optional(),
      afterCursor: z
        .string()
        .describe(
          "Echoed back as nextCursor so you can chain live polls; it does NOT fetch past events. Tailing is live-only, so an afterCursor taken from an earlier event will not replay events that occurred before this call subscribed.",
        )
        .optional(),
      waitSeconds: z.number().int().min(0).max(55).optional(),
    }),
    outputSchema: oTimeline,
    handler: async (client, args) => {
      const waitSeconds = Math.min(Math.max((args.waitSeconds as number | undefined) ?? 25, 0), 55);
      const afterCursor = (args.afterCursor as string | undefined) ?? null;
      const filter = args.filter as Record<string, unknown> | undefined;

      // Subscribe BEFORE waiting so no event slips through the gap. The client
      // fans EVERY event.appended out to EVERY listener, so re-check each one
      // against THIS call's filter: a concurrent tail with a different filter
      // must not wake us with a non-matching event. Keep waiting until one
      // actually matches (or the timeout fires).
      let resolveEvent!: (e: Record<string, unknown>) => void;
      const eventPromise = new Promise<Record<string, unknown>>((r) => (resolveEvent = r));
      const unsub = client.onEvent((params) => {
        if (eventMatchesFilter(params, filter)) resolveEvent(params);
      });

      // Capture the daemon-side subscription id so we can release it on the way
      // out; without this, every tail_events call leaks a subscription.
      let subscriptionId: string | null = null;
      try {
        const sub = (await client.call("events.tail", compact({ filter }))) as {
          subscriptionId?: string;
        };
        subscriptionId = sub.subscriptionId ?? null;
      } catch (e) {
        unsub();
        throw e;
      }

      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        const timeoutPromise = new Promise<null>((r) => {
          timer = setTimeout(() => r(null), waitSeconds * 1000);
        });
        const winner = await Promise.race([eventPromise, timeoutPromise]);
        if (winner) {
          const evt = winner as { eventId?: string; summary?: string };
          const nextCursor = evt.eventId ?? afterCursor;
          return ok({ events: [evt], nextCursor }, `1 new event: ${evt.summary ?? evt.eventId ?? "(event)"}`);
        }
        return ok({ events: [], nextCursor: afterCursor }, `No new events in ${waitSeconds}s.`);
      } finally {
        if (timer) clearTimeout(timer);
        unsub();
        // Release the daemon-side subscription. Best-effort: a failed untail
        // (e.g. the connection already dropped) must not mask the tool result.
        if (subscriptionId) {
          try {
            await client.call("events.untail", { subscriptionId });
          } catch {
            // Nothing to release if the connection is already gone.
          }
        }
      }
    },
  },
  {
    name: "score_device",
    method: "score.get",
    mutating: false,
    description:
      "The current behavioral score with its full per-signal reasoning. The result always carries the caveat that scoring is probabilistic.",
    input: z.object({ deviceId: z.string() }),
    outputSchema: oScore,
    handler: async (client, args) => {
      const r = (await client.call("score.get", { deviceId: args.deviceId })) as {
        score?: number;
        confidence?: string;
        caveat?: string;
      };
      return ok(
        r,
        `Score ${r.score ?? "?"} (${r.confidence ?? "?"} confidence). ${r.caveat ?? SCORE_CAVEAT}`,
      );
    },
  },
  {
    name: "list_alerts",
    method: "alerts.list",
    mutating: false,
    description: "Alerts with their triggering events, current state, why, and suggested actions.",
    input: z.object({
      state: z.enum(["active", "acknowledged", "resolved"]).optional(),
      severity: severity.optional(),
      deviceId: z.string().optional(),
      limit: z.number().int().optional(),
      cursor: z.string().optional(),
    }),
    outputSchema: z.object({ alerts: z.array(oAlert), nextCursor: z.string().nullish() }),
    handler: async (client, args) => {
      const filter = compact({ state: args.state, severity: args.severity, deviceId: args.deviceId });
      const r = (await client.call("alerts.list", compact({ filter: Object.keys(filter).length ? filter : undefined, limit: args.limit, cursor: args.cursor }))) as {
        alerts: unknown[];
      };
      return ok(r, `${r.alerts.length} alert(s).`);
    },
  },
  {
    name: "acknowledge_alert",
    method: "alerts.ack",
    mutating: true,
    description: "Move an active alert to acknowledged. Returns the updated alert and the appended event.",
    input: z.object({ alertId: z.string(), comment: z.string().optional() }),
    outputSchema: z.object({ alert: oAlert, event: oTimelineEvent }),
    handler: async (client, args) => {
      const r = (await client.call("alerts.ack", compact({ alertId: args.alertId, comment: args.comment }))) as {
        alert?: { state?: string };
      };
      return ok(r, `Alert ${args.alertId} is now ${r.alert?.state ?? "acknowledged"}.`);
    },
  },
  trustTool("trust_device", "trusted", "Mark a device trusted"),
  trustTool("mute_device", "muted", "Mute a device"),
  trustTool("flag_device", "flagged", "Flag a device to watch closely"),
  trustTool("clear_device_mark", "none", "Clear a device's trust mark (back to default handling)"),
  {
    name: "scan_storage",
    method: "scan.start",
    mutating: true,
    description:
      "Start a malware scan of a device's volume or a volume path. Returns the scanId immediately; poll get_scan or watch tail_events.",
    input: z.object({ deviceId: z.string().optional(), volumePath: z.string().optional() }),
    outputSchema: z.object({ scanId: z.string(), state: z.string() }),
    handler: async (client, args) => {
      const r = (await client.call("scan.start", compact({ deviceId: args.deviceId, volumePath: args.volumePath }))) as {
        scanId?: string;
        state?: string;
      };
      return ok(r, `Scan ${r.scanId ?? "?"} ${r.state ?? "started"}.`);
    },
  },
  {
    name: "cancel_scan",
    method: "scan.cancel",
    mutating: true,
    description: "Cancel a running scan. The record ends as canceled, never clean.",
    input: z.object({ scanId: z.string() }),
    outputSchema: oScan,
    handler: async (client, args) => {
      const r = (await client.call("scan.cancel", { scanId: args.scanId })) as { state?: string };
      return ok(r, `Scan ${args.scanId} is now ${r.state ?? "canceled"}.`);
    },
  },
  {
    name: "get_scan",
    method: "scan.get",
    mutating: false,
    description:
      "A scan's state, progress, per-file verdicts, and quarantine records. Pass scanId for one scan, or deviceId for that device's scans.",
    input: z.object({ scanId: z.string().optional(), deviceId: z.string().optional() }),
    outputSchema: z.union([
      oScan,
      z.object({ scans: z.array(oScanSummary), nextCursor: z.string().nullish() }),
    ]),
    handler: async (client, args) => {
      if (args.scanId) {
        const r = (await client.call("scan.get", { scanId: args.scanId })) as { state?: string };
        return ok(r, `Scan ${args.scanId}: ${r.state ?? "unknown"}.`);
      }
      if (args.deviceId) {
        const r = (await client.call("scans.list", { filter: { deviceId: args.deviceId } })) as {
          scans: unknown[];
        };
        return ok(r, `${r.scans.length} scan(s) for ${args.deviceId}.`);
      }
      throw new PlugsightError(
        "invalid_params",
        "get_scan needs either 'scanId' (one scan) or 'deviceId' (that device's scans).",
      );
    },
  },
  {
    name: "restore_quarantine",
    method: "quarantine.restore",
    mutating: true,
    description:
      "Move a quarantined file back to its original location. Requires confirm:true in the same call, because restoring bytes ClamAV flagged is deliberate. The result carries the explicit-risk sentence.",
    input: z.object({ quarantineId: z.string(), confirm: z.boolean().optional() }),
    outputSchema: z.object({
      quarantineId: z.string(),
      scanId: z.string(),
      deviceId: z.string().nullish(),
      originalPath: z.string(),
      signature: z.string(),
      state: z.string(),
      risk: z.literal(RESTORE_RISK),
      event: oTimelineEvent,
    }),
    handler: async (client, args) => {
      if (args.confirm !== true) {
        throw new PlugsightError(
          "invalid_params",
          "Restoring a quarantined file is a deliberate act: it moves bytes ClamAV flagged back into place. Resend with confirm:true only if you are certain it is a false positive.",
        );
      }
      const r = (await client.call("quarantine.restore", {
        quarantineId: args.quarantineId,
        confirm: true,
      })) as { state?: string; risk?: string };
      return ok(r, `Quarantine ${args.quarantineId} ${r.state ?? "restored"}. ${r.risk ?? RESTORE_RISK}`);
    },
  },
  {
    name: "get_policy",
    method: "policy.get",
    mutating: false,
    description: "The full policy object (scan-on-mount, quarantine, hold, notification switches, retention).",
    input: z.object({}),
    outputSchema: oPolicy,
    handler: async (client) => {
      const r = (await client.call("policy.get", {})) as { scanOnMount?: boolean };
      return ok(r, `scanOnMount=${r.scanOnMount}.`);
    },
  },
  {
    name: "set_policy",
    method: "policy.set",
    mutating: true,
    description:
      "Update policy with a partial object; unknown keys are rejected. The mount-hold key additionally requires confirm:true because it pauses mounts until scanned. Notification policy is the two booleans notifyUnsafe (alert on a yellow/red verdict, default on) and notifyNewDevice (also on every first attach, default off); the retired notificationThreshold is read-only and its writes are rejected naming those keys. Returns the full updated policy.",
    input: z
      .object({
        scanOnMount: z.boolean().optional(),
        quarantine: z.boolean().optional(),
        holdUntilScanned: z.boolean().optional(),
        scanTimeoutMinutes: z.number().int().optional(),
        clamdSocketPath: z.string().nullable().optional(),
        definitionsWarnDays: z.number().int().optional(),
        retentionDays: z.number().int().optional(),
        notifyUnsafe: z.boolean().optional(),
        notifyNewDevice: z.boolean().optional(),
        confirm: z.boolean().optional(),
      })
      .passthrough(),
    outputSchema: oPolicy,
    handler: async (client, args) => {
      const r = (await client.call("policy.set", compact(args))) as Record<string, unknown>;
      return ok(r, `Policy updated.`);
    },
  },
];

const BY_NAME = new Map(TOOLS.map((t) => [t.name, t] as const));

/** Look up a tool by name; throws if the name is not one of the 19. */
export function toolByName(name: string): ToolDef {
  const t = BY_NAME.get(name);
  if (!t) throw new Error(`Unknown tool '${name}'.`);
  return t;
}

/** Run a tool's handler, mapping any PlugsightError to a structured tool error
 * (the daemon's kind + human message, plus the plain-text rendering). */
export async function executeTool(
  client: PlugsightClient,
  tool: ToolDef,
  args: Record<string, unknown> = {},
): Promise<ToolResult> {
  try {
    return await tool.handler(client, args ?? {});
  } catch (e) {
    if (e instanceof PlugsightError) return toToolError(e);
    throw e;
  }
}
