// Canned API responses for the mock daemon.
//
// These mirror the FROZEN result shapes of the local API (docs/spec/02 APITypes
// and 03's documented JSON). One representative result per API method the 19
// tools call. Tests assert the MCP tools pass these shapes through untouched
// (plus the plain-text rendering the tools add).

export type Json = Record<string, unknown>;

export const CANNED: Record<string, unknown> = {
  "status.get": {
    monitoring: "degraded",
    daemonVersion: "1.0.0",
    uptimeSeconds: 4212,
    permissions: { inputMonitoring: false, esExtension: "inactive" },
    scanner: { available: true, engine: "clamdscan", definitionsAgeDays: 2 },
    devicesPresent: 4,
    activeAlerts: 1,
    eventCount: 128,
    monitoringGaps: [{ from: "2026-08-25T08:00:00.000Z", to: "2026-08-25T08:03:00.000Z" }],
  },

  "devices.list": {
    devices: [
      {
        deviceId: "dev_9f3ac2",
        name: "Logitech USB Receiver",
        present: true,
        firstSeen: "2026-08-20T10:00:00.000Z",
        lastSeen: "2026-08-25T09:00:00.000Z",
        vidPid: "046d:c52b",
        serial: null,
        interfaceClasses: ["hid_keyboard", "hid_mouse"],
        trust: "trusted",
        score: { value: 4, confidence: "high" },
        activeAlerts: 0,
        safetyStatus: {
          status: "green",
          reasons: [
            {
              id: "all.clear",
              sentence: "No alerts are active and nothing unusual has been observed.",
              action: "none",
            },
          ],
        },
      },
    ],
    nextCursor: null,
  },

  "devices.get": {
    deviceId: "dev_9f3ac2",
    name: "Logitech USB Receiver",
    present: true,
    firstSeen: "2026-08-20T10:00:00.000Z",
    lastSeen: "2026-08-25T09:00:00.000Z",
    vidPid: "046d:c52b",
    serial: null,
    identityBasis: "vidpid+serial",
    trust: "trusted",
    trustNote: "my keyboard",
    trustSetBy: "ui",
    trustSetAt: "2026-08-20T10:05:00.000Z",
    interfaces: [
      { seq: 0, class: 3, subclass: 1, protocol: 1, role: "keyboard" },
      { seq: 1, class: 3, subclass: 1, protocol: 2, role: "mouse" },
    ],
    score: { value: 4, confidence: "high" },
    eventCount: 12,
    scanCount: 0,
    trustHistory: [
      { tier: "trusted", actor: "ui", at: "2026-08-20T10:05:00.000Z", note: "my keyboard" },
    ],
    topology: { port: "20-1.2", hubPath: ["1", "2"] },
    isStorage: false,
    safetyStatus: {
      status: "green",
      reasons: [
        {
          id: "all.clear",
          sentence: "No alerts are active and nothing unusual has been observed.",
          action: "none",
        },
      ],
    },
  },

  "timeline.list": {
    events: [
      {
        eventId: "evt_01H8XYZ",
        at: "2026-08-25T09:14:02.113Z",
        kind: "hid.typing_burst",
        severity: "warning",
        deviceId: "dev_2ab919",
        summary:
          "Started typing 0.4 seconds after it was plugged in. Human typists need a few seconds.",
        actor: "system",
      },
    ],
    nextCursor: null,
  },

  "events.get": {
    event: {
      eventId: "evt_01H8XYZ",
      at: "2026-08-25T09:14:02.113Z",
      kind: "hid.typing_burst",
      severity: "warning",
      deviceId: "dev_2ab919",
      summary:
        "Started typing 0.4 seconds after it was plugged in. Human typists need a few seconds.",
      actor: "system",
    },
    why: "plug_to_type_latency 410ms is below the 2000ms human floor.",
    context: {
      detail: { v: 1, plugToTypeMs: 410 },
      deviceId: "dev_2ab919",
      deviceName: "Unknown keyboard",
      trust: "none",
      alertId: "alt_7",
    },
    suggestedActions: [
      { tool: "acknowledge_alert", label: "Acknowledge the alert" },
      { tool: "flag_device", label: "Flag the device" },
    ],
  },

  "events.tail": { subscriptionId: "sub_1" },
  "events.untail": { ok: true },

  "score.get": {
    score: 78,
    confidence: "medium",
    signals: [
      { id: "plug_to_type_latency", observed: "410ms", verdict: "suspicious", weight: 0.35 },
      { id: "inter_key_timing", observed: "mean 21ms, stddev 3ms", verdict: "suspicious", weight: 0.35 },
    ],
    explanation: "Score 78 (medium confidence) from 2 signals.",
    // Charter item: the caveat rides on every score payload.
    caveat: "Behavioral scoring is probabilistic and a patient attacker can evade it.",
    sensorAvailable: true,
  },

  "alerts.list": {
    alerts: [
      {
        alertId: "alt_7",
        deviceId: "dev_2ab919",
        deviceName: "Unknown keyboard",
        rule: "hidden_hid",
        severity: "critical",
        state: "active",
        at: "2026-08-25T09:14:02.200Z",
        raisedAt: "2026-08-25T09:14:02.200Z",
        updatedAt: "2026-08-25T09:14:02.200Z",
        summary: "A device that types like a machine appeared as a keyboard.",
        why: "plug_to_type_latency 410ms + inter_key_timing stddev 3ms.",
        suggestedActions: [
          { tool: "acknowledge_alert", label: "Acknowledge" },
          { tool: "flag_device", label: "Flag device" },
        ],
        ackedBy: null,
        ackedAt: null,
        ackComment: null,
      },
    ],
    nextCursor: null,
  },

  "alerts.ack": {
    alert: {
      alertId: "alt_7",
      deviceId: "dev_2ab919",
      deviceName: "Unknown keyboard",
      rule: "hidden_hid",
      severity: "critical",
      state: "acknowledged",
      at: "2026-08-25T09:14:02.200Z",
      raisedAt: "2026-08-25T09:14:02.200Z",
      updatedAt: "2026-08-25T09:20:00.000Z",
      summary: "A device that types like a machine appeared as a keyboard.",
      why: "plug_to_type_latency 410ms + inter_key_timing stddev 3ms.",
      suggestedActions: [{ tool: "flag_device", label: "Flag device" }],
      ackedBy: "mcp:claude-code",
      ackedAt: "2026-08-25T09:20:00.000Z",
      ackComment: "seen",
    },
    event: {
      eventId: "evt_ack1",
      at: "2026-08-25T09:20:00.000Z",
      kind: "alert.acknowledged",
      severity: "critical",
      deviceId: "dev_2ab919",
      summary: "Alert acknowledged by mcp:claude-code. seen",
      actor: "mcp:claude-code",
    },
  },

  "trust.set": {
    device: {
      deviceId: "dev_2ab919",
      name: "Unknown keyboard",
      present: true,
      firstSeen: "2026-08-25T09:13:00.000Z",
      lastSeen: "2026-08-25T09:14:02.000Z",
      vidPid: "1d6b:0104",
      serial: null,
      identityBasis: "vidpid",
      trust: "flagged",
      trustNote: null,
      trustSetBy: "mcp:claude-code",
      trustSetAt: "2026-08-25T09:21:00.000Z",
      interfaces: [{ seq: 0, class: 3, subclass: 1, protocol: 1, role: "keyboard" }],
      score: { value: 78, confidence: "medium" },
      eventCount: 5,
      scanCount: 0,
      trustHistory: [
        { tier: "flagged", actor: "mcp:claude-code", at: "2026-08-25T09:21:00.000Z", note: null },
      ],
      topology: null,
      isStorage: false,
      safetyStatus: {
        status: "yellow",
        reasons: [
          {
            id: "behavior.elevated",
            sentence: "Typing from this device looks unusual.",
            action: "unplug",
          },
        ],
      },
    },
    event: {
      eventId: "evt_trust1",
      at: "2026-08-25T09:21:00.000Z",
      kind: "trust.changed",
      severity: "info",
      deviceId: "dev_2ab919",
      summary: "Trust set to flagged by mcp:claude-code.",
      actor: "mcp:claude-code",
    },
    caveat:
      "Trust is advisory: a device's identity can be forged, so a trusted mark is not proof of safety.",
  },

  "scan.start": { scanId: "scan_42", state: "running" },

  "scan.cancel": {
    scanId: "scan_42",
    deviceId: "dev_9f3ac2",
    volumePath: "/Volumes/USB",
    engine: "clamdscan",
    defsAgeDays: 2,
    state: "canceled",
    progress: null,
    startedAt: "2026-08-25T09:22:00.000Z",
    finishedAt: "2026-08-25T09:22:30.000Z",
    filesScanned: 12,
    startedBy: "mcp:claude-code",
    verdicts: [],
    quarantine: [],
    reason: "The scan was canceled.",
  },

  "scan.get": {
    scanId: "scan_42",
    deviceId: "dev_9f3ac2",
    volumePath: "/Volumes/USB",
    engine: "clamdscan",
    defsAgeDays: 2,
    state: "running",
    progress: null,
    startedAt: "2026-08-25T09:22:00.000Z",
    finishedAt: null,
    filesScanned: 3,
    startedBy: "mcp:claude-code",
    verdicts: [],
    quarantine: [],
    reason: null,
  },

  "scans.list": {
    scans: [
      {
        scanId: "scan_42",
        deviceId: "dev_9f3ac2",
        volumePath: "/Volumes/USB",
        engine: "clamdscan",
        state: "running",
        startedAt: "2026-08-25T09:22:00.000Z",
        finishedAt: null,
        filesScanned: 3,
      },
    ],
    nextCursor: null,
  },

  // Being added to the daemon in parallel (validated post-N8 by the round-trip).
  // The MCP server maps restore_quarantine -> quarantine.restore and passes this
  // shape through; the explicit-risk sentence rides in the response.
  "quarantine.restore": {
    quarantineId: "q_9",
    scanId: "scan_42",
    deviceId: "dev_9f3ac2",
    originalPath: "/Volumes/USB/invoice.pdf",
    signature: "Eicar-Test-Signature",
    state: "restored",
    risk: "You are restoring a file ClamAV flagged; only do this if you are certain it is a false positive.",
    event: {
      eventId: "evt_restore1",
      at: "2026-08-25T09:25:00.000Z",
      kind: "quarantine.restored",
      severity: "notice",
      deviceId: "dev_9f3ac2",
      summary: "Restored 'invoice.pdf' from quarantine (flagged Eicar-Test-Signature).",
      actor: "mcp:claude-code",
    },
  },

  "policy.get": {
    scanOnMount: false,
    quarantine: true,
    holdUntilScanned: false,
    scanTimeoutMinutes: 15,
    clamdSocketPath: null,
    definitionsWarnDays: 7,
    retentionDays: 365,
    notifyUnsafe: true,
    notifyNewDevice: false,
    notificationThreshold: "warning",
  },

  "policy.set": {
    scanOnMount: true,
    quarantine: true,
    holdUntilScanned: false,
    scanTimeoutMinutes: 15,
    clamdSocketPath: null,
    definitionsWarnDays: 7,
    retentionDays: 365,
    notifyUnsafe: true,
    notifyNewDevice: false,
    notificationThreshold: "warning",
  },
};

// A canned event.appended notification payload (timeline-event shape) the mock
// pushes to exercise the tail_events early-return path.
export const CANNED_EVENT_APPENDED = {
  eventId: "evt_live1",
  at: "2026-08-25T09:30:00.000Z",
  kind: "device.attached",
  severity: "notice",
  deviceId: "dev_new1",
  summary: "A new USB device attached: SanDisk Cruzer.",
  actor: "system",
};
