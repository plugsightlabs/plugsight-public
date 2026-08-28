# 06. Data model

One SQLite database (WAL, GRDB migrations), one writer (the daemon), all reads through the API.
The schema exists to serve one artifact well: the readable timeline. Everything else is indexes
around it.

## Device identity, honestly

USB gives us no reliable identity (L9). The matching key, in order:

1. `(vid, pid, serial)` when a serial string is present and non-trivial (longer than 3 chars, not
   all zeros).
2. Otherwise a **shape fingerprint**: SHA-256 over vid, pid, the ordered interface triples
   (class, subclass, protocol), and the descriptor strings. Two serialless identical sticks are
   one device to us, and the device record says so ("identity based on device shape; identical
   devices are indistinguishable").

A device row is created on first sight and reused on every re-attach that matches. The
`identityBasis` column (`serial` or `shape`) is rendered in the inspector, because trust decisions
deserve to know how sure the identity is.

## Tables

```sql
CREATE TABLE devices (
  id            TEXT PRIMARY KEY,          -- 'dev_' + ULID
  identity_key  TEXT NOT NULL UNIQUE,
  identity_basis TEXT NOT NULL CHECK (identity_basis IN ('serial','shape')),
  vid           INTEGER NOT NULL,
  pid           INTEGER NOT NULL,
  serial        TEXT,
  vendor_name   TEXT,                      -- descriptor string, may be junk or empty
  product_name  TEXT,
  display_name  TEXT NOT NULL,             -- computed: product string, else class-derived fallback
  first_seen_at TEXT NOT NULL,             -- ISO-8601 UTC, milliseconds
  last_seen_at  TEXT NOT NULL,
  present       INTEGER NOT NULL DEFAULT 0,
  trust_tier    TEXT NOT NULL DEFAULT 'none'
                CHECK (trust_tier IN ('none','trusted','muted','flagged')),
  trust_note    TEXT,
  trust_set_by  TEXT,                      -- actor string
  trust_set_at  TEXT
);

CREATE TABLE device_interfaces (
  device_id     TEXT NOT NULL REFERENCES devices(id),
  seq           INTEGER NOT NULL,          -- interface order within the config
  usb_class     INTEGER NOT NULL,
  usb_subclass  INTEGER NOT NULL,
  usb_protocol  INTEGER NOT NULL,
  role          TEXT NOT NULL,             -- plain-language word: 'keyboard','storage','network',
                                           -- 'mouse','audio','video','smartcard','hub','vendor','other'
  PRIMARY KEY (device_id, seq)
);

CREATE TABLE events (
  id         TEXT PRIMARY KEY,             -- 'evt_' + ULID (ULID gives time-ordered ids;
  at         TEXT NOT NULL,                --  cursor pagination is 'WHERE id < ?' newest-first)
  kind       TEXT NOT NULL,                -- namespaced, see catalog below
  severity   TEXT NOT NULL CHECK (severity IN ('info','notice','warning','critical')),
  device_id  TEXT REFERENCES devices(id),  -- NULL for system events (daemon start, gaps)
  actor      TEXT NOT NULL DEFAULT 'system', -- 'system' | 'ui' | 'mcp:<name>' | 'cli'
  summary    TEXT NOT NULL,                -- the one-to-two sentence plain-language payload
  detail     TEXT NOT NULL DEFAULT '{}',   -- JSON, kind-specific, schema-versioned
  alert_id   TEXT REFERENCES alerts(id)    -- set when this event belongs to an alert
);
CREATE INDEX idx_events_at ON events(at DESC);
CREATE INDEX idx_events_device ON events(device_id, at DESC);
CREATE INDEX idx_events_kind ON events(kind, at DESC);

CREATE TABLE alerts (
  id          TEXT PRIMARY KEY,            -- 'alr_' + ULID
  device_id   TEXT REFERENCES devices(id),
  rule        TEXT NOT NULL,               -- 'R1'..'R6', 'behavioral_score', 'scan_finding'
  severity    TEXT NOT NULL CHECK (severity IN ('notice','warning','critical')),
  state       TEXT NOT NULL DEFAULT 'active'
              CHECK (state IN ('active','acknowledged','resolved')),
  raised_at   TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  summary     TEXT NOT NULL,
  why         TEXT NOT NULL,               -- the reasoning paragraph, plain language, numbers included
  acked_by    TEXT, acked_at TEXT, ack_comment TEXT
);

CREATE TABLE score_snapshots (
  id          TEXT PRIMARY KEY,            -- 'scr_' + ULID
  device_id   TEXT NOT NULL REFERENCES devices(id),
  at          TEXT NOT NULL,
  score       INTEGER NOT NULL CHECK (score BETWEEN 0 AND 100),
  confidence  TEXT NOT NULL CHECK (confidence IN ('low','medium','high')),
  signals     TEXT NOT NULL                -- JSON array in 03's score shape
);
CREATE INDEX idx_scores_device ON score_snapshots(device_id, at DESC);

CREATE TABLE scans (
  id           TEXT PRIMARY KEY,           -- 'scn_' + ULID
  device_id    TEXT REFERENCES devices(id),
  volume_path  TEXT NOT NULL,
  engine       TEXT NOT NULL,              -- 'clamdscan' | 'clamscan'
  defs_age_days INTEGER,
  state        TEXT NOT NULL CHECK (state IN
               ('running','clean','infected','failed','canceled','skipped')),
  started_at   TEXT NOT NULL,
  finished_at  TEXT,
  files_scanned INTEGER NOT NULL DEFAULT 0,
  started_by   TEXT NOT NULL               -- actor
);

CREATE TABLE scan_findings (
  scan_id        TEXT NOT NULL REFERENCES scans(id),
  file_path      TEXT NOT NULL,
  signature      TEXT NOT NULL,
  action         TEXT NOT NULL CHECK (action IN ('quarantined','reported_only')),
  quarantine_path TEXT,                    -- sha256-named file when quarantined
  PRIMARY KEY (scan_id, file_path)
);

CREATE TABLE policy (
  key        TEXT PRIMARY KEY,             -- one row per top-level policy key
  value      TEXT NOT NULL,                -- JSON
  updated_at TEXT NOT NULL,
  updated_by TEXT NOT NULL
);
```

Trust history is not a table: every trust change is an event (`trust.changed` with the old and new
tier in detail), and the inspector's trust history is an event query. One storage mechanism for
"things that happened" keeps the timeline complete by construction: there is no side channel a
change can happen in without appearing in the record.

## Event kind catalog

Kinds are namespaced, closed-set per release, and the drift gate fails if the UI or docs mention a
kind the daemon does not emit. The v1 catalog:

| Kind | Severity default | Summary example (the actual template ships in code, one per kind) |
|---|---|---|
| `device.attached` | info | "SanDisk Ultra plugged in. Presents as: storage." |
| `device.detached` | info | "SanDisk Ultra unplugged after 22 minutes." |
| `device.interfaces_changed` | warning | "This device re-enumerated with more interfaces than before." (R5) |
| `mismatch.detected` | per rule | "Presented as a charger, but also registered a keyboard." (R1-R4) |
| `mismatch.allowlisted` | info | "Composite device matching the security-key shape." |
| `hid.typing_burst` | notice | "Typed 47 keys in 1.1 seconds, starting 0.4 s after plug-in." |
| `score.changed` | notice/warning | "Behavior score rose to 78 (medium confidence)." |
| `alert.raised` / `alert.acknowledged` / `alert.resolved` | mirror alert | state changes, with actor |
| `trust.changed` | info | "Marked trusted by agent claude-code: 'my YubiKey'." |
| `volume.mounted` / `volume.unmounted` | info | "Volume UNTITLED (14.9 GB) mounted from SanDisk Ultra." |
| `volume.held` / `volume.released` | notice | mount-hold lifecycle, ES path only |
| `scan.started` / `scan.finished` / `scan.skipped` | info; finding raises alert | "Scan skipped: no scanner installed." |
| `quarantine.restored` | notice | "Restored 'invoice.pdf' from quarantine (flagged Eicar-Test-Signature), by agent claude-code." (D6) |
| `esext.iokit_open` | info | "Terminal opened this device's storage interface." |
| `daemon.started` / `daemon.stopped` | info | lifecycle |
| `monitoring.gap` | notice | "Monitoring was off between 02:14 and 08:03." |

The `summary` column stores the rendered sentence at write time (not a template reference), so the
historical record never changes meaning when copy improves in a later version. `detail` carries a
`v` field per kind for forward-compatible parsing.

## Retention

Default: events and score snapshots kept 365 days, pruned by a daily job; devices, alerts, scans,
and findings kept indefinitely (they are the durable dossier). Policy-adjustable. Pruning writes a
single `monitoring.gap`-style marker event summarizing what range was pruned, so a trimmed
timeline still says it was trimmed.

## Size expectations

An ordinary machine sees a few dozen events a day; a conference-dock day maybe a few hundred.
SQLite with these indexes idles at this load. The 500-cap on `timeline.list` pages plus ULID
cursors keeps every query bounded. No further cleverness is warranted (YAGNI applies to storage
optimizations too).
