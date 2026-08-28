// Migrations.swift
//
// The SQLite schema is a FROZEN CONTRACT (docs/spec/06, 07): additive-only after
// this node. The DDL below is transcribed VERBATIM from 06 — column names,
// types, CHECK constraints, and indexes exactly as written. The introspection
// test in StoreTests.swift asserts the produced schema matches.
//
// GRDB migrations run inside a transaction. SQLite resolves table references at
// row-write time, not at CREATE time, so forward FK references (e.g.
// events.alert_id -> alerts(id)) are fine; we create `alerts` before `events`
// anyway. FK enforcement itself is a PRAGMA enabled in EventStore's setup.

import GRDB

enum PlugsightSchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE devices (
              id            TEXT PRIMARY KEY,              -- 'dev_' + ULID
              identity_key  TEXT NOT NULL UNIQUE,
              identity_basis TEXT NOT NULL CHECK (identity_basis IN ('serial','shape')),
              vid           INTEGER NOT NULL,
              pid           INTEGER NOT NULL,
              serial        TEXT,
              vendor_name   TEXT,
              product_name  TEXT,
              display_name  TEXT NOT NULL,
              first_seen_at TEXT NOT NULL,                 -- ISO-8601 UTC, milliseconds
              last_seen_at  TEXT NOT NULL,
              present       INTEGER NOT NULL DEFAULT 0,
              trust_tier    TEXT NOT NULL DEFAULT 'none' CHECK (trust_tier IN ('none','trusted','muted','flagged')),
              trust_note    TEXT,
              trust_set_by  TEXT,
              trust_set_at  TEXT
            )
            """)

            try db.execute(sql: """
            CREATE TABLE device_interfaces (
              device_id     TEXT NOT NULL REFERENCES devices(id),
              seq           INTEGER NOT NULL,
              usb_class     INTEGER NOT NULL,
              usb_subclass  INTEGER NOT NULL,
              usb_protocol  INTEGER NOT NULL,
              role          TEXT NOT NULL,                 -- 'keyboard','storage','network','mouse','audio','video','smartcard','hub','vendor','other'
              PRIMARY KEY (device_id, seq)
            )
            """)

            try db.execute(sql: """
            CREATE TABLE alerts (
              id          TEXT PRIMARY KEY,                -- 'alr_' + ULID
              device_id   TEXT REFERENCES devices(id),
              rule        TEXT NOT NULL,                   -- 'R1'..'R6','behavioral_score','scan_finding'
              severity    TEXT NOT NULL CHECK (severity IN ('notice','warning','critical')),
              state       TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','acknowledged','resolved')),
              raised_at   TEXT NOT NULL,
              updated_at  TEXT NOT NULL,
              summary     TEXT NOT NULL,
              why         TEXT NOT NULL,
              acked_by    TEXT, acked_at TEXT, ack_comment TEXT
            )
            """)

            try db.execute(sql: """
            CREATE TABLE events (
              id         TEXT PRIMARY KEY,                 -- 'evt_' + ULID
              at         TEXT NOT NULL,
              kind       TEXT NOT NULL,
              severity   TEXT NOT NULL CHECK (severity IN ('info','notice','warning','critical')),
              device_id  TEXT REFERENCES devices(id),
              actor      TEXT NOT NULL DEFAULT 'system',   -- 'system' | 'ui' | 'mcp:<name>' | 'cli'
              summary    TEXT NOT NULL,
              detail     TEXT NOT NULL DEFAULT '{}',
              alert_id   TEXT REFERENCES alerts(id)
            )
            """)

            try db.execute(sql: "CREATE INDEX idx_events_at ON events(at DESC)")
            try db.execute(sql: "CREATE INDEX idx_events_device ON events(device_id, at DESC)")
            try db.execute(sql: "CREATE INDEX idx_events_kind ON events(kind, at DESC)")

            try db.execute(sql: """
            CREATE TABLE score_snapshots (
              id          TEXT PRIMARY KEY,                -- 'scr_' + ULID
              device_id   TEXT NOT NULL REFERENCES devices(id),
              at          TEXT NOT NULL,
              score       INTEGER NOT NULL CHECK (score BETWEEN 0 AND 100),
              confidence  TEXT NOT NULL CHECK (confidence IN ('low','medium','high')),
              signals     TEXT NOT NULL
            )
            """)

            try db.execute(sql: "CREATE INDEX idx_scores_device ON score_snapshots(device_id, at DESC)")

            try db.execute(sql: """
            CREATE TABLE scans (
              id           TEXT PRIMARY KEY,               -- 'scn_' + ULID
              device_id    TEXT REFERENCES devices(id),
              volume_path  TEXT NOT NULL,
              engine       TEXT NOT NULL,                  -- 'clamdscan' | 'clamscan'
              defs_age_days INTEGER,
              state        TEXT NOT NULL CHECK (state IN ('running','clean','infected','failed','canceled','skipped')),
              started_at   TEXT NOT NULL,
              finished_at  TEXT,
              files_scanned INTEGER NOT NULL DEFAULT 0,
              started_by   TEXT NOT NULL
            )
            """)

            try db.execute(sql: """
            CREATE TABLE scan_findings (
              scan_id        TEXT NOT NULL REFERENCES scans(id),
              file_path      TEXT NOT NULL,
              signature      TEXT NOT NULL,
              action         TEXT NOT NULL CHECK (action IN ('quarantined','reported_only')),
              quarantine_path TEXT,
              PRIMARY KEY (scan_id, file_path)
            )
            """)

            try db.execute(sql: """
            CREATE TABLE policy (
              key        TEXT PRIMARY KEY,
              value      TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              updated_by TEXT NOT NULL
            )
            """)
        }

        return migrator
    }
}
