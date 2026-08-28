# 04. UX: stories, architecture, surfaces

Produced with the ux-architect-greenfield method: FRAME with a derived-vs-invented ledger, the
full story matrix, object model and navigation, the surface inventory with complete state sets,
and the row-to-path completeness check. The design canon governs throughout. A fresh-eyes canon
review was dispatched on the first draft of this document; its findings are folded in below and
summarized in the canon check section at the end.

## FRAME

1. **Goal**: "I can see what plugged into my Mac, what it claimed to be, and what it then did, in
   words I understand." (derived: 00)
2. **Who runs it**: both. A human in the menu-bar app, and an agent over MCP. Peers over one API.
   (derived: brief)
3. **Trigger and end state**: triggered by a device event or by curiosity/suspicion; closed when
   the user or agent has read the explanation and made a decision (trust, mute, flag, scan,
   acknowledge, or nothing). (derived: 00; the "or nothing" close is invented: an informational
   event needs no decision, and forcing one would be noise)
4. **Success, observably**: a first-time user can answer the three questions for any device in the
   list without external help; an agent can produce the same answer from tool calls alone; alerts
   name a next action and none dead-ends. (derived: canon + 00)
5. **Out of scope**: blocking UX (nothing to configure for a capability we do not have), fleet
   views, multi-machine anything, historical analytics dashboards. (derived: 00 non-goals;
   "no analytics dashboard" is invented: v1 is a monitor, not a BI tool)

### Personas

- **Maya**, an individual Mac user with reasons to care (journalist, developer, frequent
  traveler). Not a security professional. Reads alerts, decides, moves on. (invented, but
  constrained by 00's "personal tool" scope)
- **The operating agent**: Claude or a peer, connected over MCP, asked things like "anything
  plug in while I was away?" or standing watch during a talk. It needs machine-shaped facts and
  the same plain-language summaries, and its actions must be visible to Maya afterward. (derived:
  brief, agent-first)
- **The owner-operator** (dogfooding case): technical, checks the timeline after an incident or a
  conference, tunes policy once and forgets it. (derived: 08 dogfooding)

## Shared vocabulary (both faces, same words)

- **Severity** is an ordered ladder: info < notice < warning < critical. Wherever a user picks a
  threshold, the options describe themselves in plain words ("Only critical", "Warnings and
  critical", "Everything") rather than asking the user to rank the ladder from memory.
- **Trust tiers** are `trusted`, `muted`, `flagged`, and `none` on the wire (05 defines their
  detection effects). The display word for `none` is **Default**, in the UI and in MCP text
  renderings alike. Each tier has a one-line consequence sentence, written once and rendered by
  both faces: Trusted "routine alerts off for this device; a critical finding still alerts";
  Default "normal alerting"; Muted "no notifications from this device; everything still
  recorded"; Flagged "every event from this device notifies, and it leads lists".
- **Alert lifecycle**: `active` (needs eyes), `acknowledged` (a person or agent saw it; it leaves
  the popover but stays on the timeline and the device dossier), `resolved` (the condition ended:
  the device detached, a rescan came back clean; set by the system, recorded with a reason).
- **Score** renders under the label **Behavior**, as a number plus a tier word (low / elevated /
  high). Its meaning line ("how much this device's typing behaves like an automated attack")
  lives in a tooltip and in the score disclosure, never as prose permanently stacked on a
  surface.
- Degraded-mode copy names user-recognizable things only: "Input Monitoring", "the system
  extension", "the scanner". Internal names (IOKit, ES, clamd) never reach a screen; they
  survive as tooltip detail for the curious.

## Story matrix

| # | Story | Actor | Path | Expected behaviour | Recovery | End state | Acceptance |
|---|---|---|---|---|---|---|---|
| 1a | First run: install and onboard | Maya | happy | Onboarding window explains the three permissions (Input Monitoring, system extension, Full Disk Access for scanning) one at a time, each with what turns on, what stays off without it, and a Skip | - | Monitoring active; status glyph idle | Each permission step names its capability gain in one sentence; Skip is visible on every step |
| 1b | First run | Maya | error: Input Monitoring denied | App shows degraded state, not failure: "typing-behavior scoring is off" with a Grant button deep-linking to System Settings | Grant later from Settings surface | Degraded monitoring, honestly labeled | Status popover shows "degraded" with the specific missing grant and a working deep link |
| 1c | First run | Maya | error: extension approval refused in System Settings | Same degraded pattern; extension row shows "not approved" with Open System Settings action; app never nags on a timer | Approve later; row updates live | Monitoring continues at standard fidelity; copy says only "system extension" | Refusing costs only extension-fidelity features and the UI says which, in plain words |
| 1d | First run | Maya | edge: app launched outside /Applications | App detects the wrong location before extension activation and shows the move instruction in the onboarding step | Move to /Applications, relaunch | Normal onboarding | The in-app location check and instruction fire before activation is attempted |
| 1e | Months later | Maya | edge: a granted permission is revoked in System Settings | Daemon notices on its next check; the same degraded pattern as 1b appears in glyph, popover footer, and Settings | Re-grant from Settings row | Degraded state visible within a minute of revocation | Revocation mid-life produces the identical degraded UI as denial at onboarding |
| 2a | A device attaches | Maya | happy | Glyph ticks; popover top row shows "SanDisk Ultra plugged in just now" with its plain-language roles | - | Row readable, no action forced | Popover row states name and roles in plain words within 2 s of attach |
| 2b | A device attaches | Maya | edge: descriptor strings empty or junk | Row falls back to a plain fallback name ("Unnamed keyboard"), never raw hex alone | - | Legible row regardless of descriptor quality | No row ever renders VID/PID as its only label |
| 2c | A device attaches | agent | happy (agent watch) | `tail_events` returns the same attach event with the same summary sentence | - | Agent reports to its user | Event JSON summary equals the popover sentence |
| 3a | Hidden keyboard in a "charger" | Maya | happy (mismatch alert) | Notification + glyph alert state; alert says what it claimed, what it also enumerated, and the three-sentence why. One primary action: Details (opens the expanded timeline row); Flag and Trust sit in its overflow and behave exactly like the inspector's trust control | - | Alert acknowledged or device flagged | Alert body answers claimed-role vs actual-roles in plain words; Details is the single primary action |
| 3b | Same | Maya | edge: device is a known legit composite (security-key shape: HID + smartcard) | Mismatch rules whitelist known-legit patterns (05); no alert, info event only | - | Quiet timeline entry | Security-key pattern produces no alert on default policy |
| 3c | Same | agent | happy | `list_alerts` carries the same alert with `suggestedActions` naming `flag_device` etc. | - | Agent flags or reports | Each suggested action names a tool in this contract |
| 4a | Typing-burst score | Maya | happy (alert) | Warning alert while burst is in progress or seconds after: "started typing 0.4 s after plug-in"; primary: Details; Acknowledge and Flag in the overflow | - | User decides | Alert lands within 5 s of the qualifying burst |
| 4b | Same | Maya | error: Input Monitoring off | No behavioral alert possible; the degraded banner (1b) is the standing explanation; mismatch rules still fire | Grant from Settings | Honest degraded coverage | No score number renders anywhere while the sensor is off; surfaces show the sensor-off explanation instead (never "no typing observed") |
| 4c | Same | agent | happy | `score_device` returns breakdown with per-signal verdicts and the mandatory caveat | - | Agent explains score to its user | Caveat field present in every score payload |
| 5a | Storage stick mounts | Maya | happy (scan on mount, clean) | Timeline: mounted, scan started, scan clean, three quiet info events; no notification for clean | - | Silence is the success signal | Clean scan produces no notification on default policy |
| 5b | Same | Maya | happy (infected, quarantined) | Critical alert names file, signature, action taken (quarantined); Details opens the scan record, where Restore and Eject live | Restore from the scan record if it was a false positive | File quarantined, user informed | Alert names file path, signature, and the completed action; the scan record offers Restore |
| 5c | Same | Maya | error: ClamAV not installed | Scan-on-mount silently impossible is forbidden: timeline event "scan skipped: scanner not installed" + Settings scanner row shows install fix | Install via the guided step in Settings | Scans resume on next mount | The skip is a visible timeline event, never silent |
| 5d | Same | Maya | edge: huge volume (500 GB) | Scan runs with progress visible on the device row and in the scan record; user can keep using the volume (notify-only default); Cancel available in the scan record | Cancel scan | Partial scan recorded as such | Progress visible in both places; canceled scans record "canceled", never "clean" |
| 5e | Same | agent | happy | `scan_storage` then `get_scan` polling reaches a terminal state with per-file verdicts; `cancel_scan` mirrors the human Cancel | - | Agent reports result | Scan states are exactly: running, clean, infected, failed, canceled, skipped |
| 5f | Same | Maya | error: scan fails (engine error, unreadable volume) | Scan record shows `failed` with the reason and a Retry action; a notice event lands in the timeline | Retry scan (or fix named cause) | Failure legible, retryable | `failed` is never rendered as clean, and its state carries a Retry control |
| 5g | Same | Maya | error: quarantine move fails (read-only volume) | Alert states the finding AND that the file could not be moved ("reported only"); suggested action: Eject | Eject from the scan record | Honest containment claim | The alert never claims quarantine when the move failed |
| 6a | Trust a known device | Maya | happy | In the device inspector: the trust control (segmented, Trusted / Default / Muted / Flagged). Change applies immediately with an undo toast; the first trust action ever shows a one-time note carrying the forgeability caveat | Undo toast, or set back to Default | Device shows trusted badge | The caveat note appears on the user's first-ever trust action; critical-score alerts still get through (05 rule) |
| 6b | Same | agent | happy | `trust_device` with note; response carries the same caveat sentence (03); timeline event attributes "trusted by agent <name>" | `clear_device_mark` | Same end state as 6a | Attribution string visible in UI timeline afterward; caveat present in the tool response |
| 6c | Same | Maya | edge: trusting while device absent | Allowed; copy says "applies next time it connects" | - | Mark stored | The absent case is stated, not silently accepted |
| 7a | Morning-after review | Maya | happy | Open timeline window: last night's events grouped by device, gaps in monitoring shown as explicit rows | - | User can narrate what happened | Monitoring-gap rows render whenever the daemon was down while the machine was up |
| 7b | Same | Maya | edge: 20+ devices, hundreds of events | Timeline virtualizes; the device filter is a searchable picker (never 20 flat choices), severity filter is one chip | Clear filters | Usable at conference-dock scale | With 20 devices present the device picker searches, and the devices list stays one screen sorted by last activity |
| 7c | Same | agent | happy | `get_timeline` with since/severity filters; pagination by cursor | - | Agent summarizes; summaries quotable | Cursor pagination returns stable order across pages |
| 8a | Policy: hold new drives until scanned | owner-operator | happy | Settings toggle labeled "Hold new drives until scanned", one-line row copy; the full consequence paragraph lives in the confirm step | Toggle off | New volumes held until scanned | Enabling is impossible (control disabled, reason as inline text in the row) unless the extension is active and a scanner is present: prevent at the control |
| 8b | Same | owner-operator | error: extension inactive | Toggle disabled with the reason inline ("needs the system extension; activate it above") linking the enabling row | Activate extension first | Unchanged policy | The disabled reason is visible text, reachable without hover, naming the exact missing prerequisite |
| 8c | Same | agent | happy | `set_policy` with `confirm:true`; missing confirm returns the explanatory error | Retry with confirm | Policy updated + event | Error message for missing confirm explains the consequence, not just "confirm required" |
| 9a | Daemon down | Maya | error: daemon crashed or stopped | Glyph shows stopped state; popover reduces to one message and one action (Start monitoring); app relaunches agent via SMAppService | Start monitoring | Monitoring resumes; gap recorded | Stopped state is visually distinct from idle and from degraded |
| 9b | Same | agent | error | Every tool returns `daemon_unreachable` with the literal fix | Human starts app | Agent relays the fix verbatim | The error text alone is enough for a non-technical user to recover |

Dismissals (interrogated, no row): concurrent conflicting trust writes from both faces (last write
wins with both events in the timeline; the record is the resolution, no UI needed); offline
(product is fully local, network state is irrelevant by design); unauthorized actors (single-user
tool behind socket perms + token, no in-app auth boundary); localization overflow (v1 ships
English-only; "design for the longest language" is honored structurally by not baking copy into
fixed-width chrome, and localization is an 09 question); notification-permission denied (macOS
setting; glyph and popover carry the same information, notifications are additive only).

## Object model

| Object | Key fields | Relationships | Owner/scope |
|---|---|---|---|
| Device | name, vid/pid, serial, roles (plain-language), present, first/last seen, trust tier (+ consequence line), behavior score | has interfaces, events, alerts, scans | per machine |
| Interface | class/subclass/protocol raw + role word | belongs to device | per device |
| Event | at, kind, severity, summary sentence, actor, detail | belongs to device (nullable for system events) | per machine |
| Alert | state (active / acknowledged / resolved, lifecycle above), severity, why, suggested actions | groups events; belongs to device | per machine |
| Scan | state (running / clean / infected / failed / canceled / skipped), engine, verdicts, quarantine records | belongs to device + volume | per machine |
| Policy | scan on mount, hold new drives, notification threshold, scanner config | singleton | per machine |

Five nouns plus a singleton, all meaning what a first-time user thinks they mean. The two labels
that needed design work, "Behavior" (score) and the trust tiers, carry their one-line meanings via
the shared vocabulary section, delivered as tooltips and control captions, not stacked prose.

## Navigation

One menu-bar item, one popover, one main window, plus OS-owned surfaces (notifications, System
Settings). Inside the main window: a sidebar with exactly three items (Timeline, Devices,
Settings). Device detail opens as an inspector pane inside the window, never a modal: peers stay
navigable without closing anything (canon). Alerts are not a fourth section; an alert renders as
its expanded timeline row (the canonical alert surface), reached from the notification, the
popover, or the timeline itself, with the device inspector one click away. Every other place an
alert appears (notification banner, popover row) is an echo that leads here, so the alert has one
canonical rendering and no duplicated controls.

## Surface inventory

| Surface | Purpose (one sentence) |
|---|---|
| Menu-bar glyph | Show at a glance whether anything needs attention. |
| Popover | Last events, active alerts, and status, three seconds after a glance. |
| Main window: Timeline | The readable forensic record, filterable; expanded rows are the canonical alert surface. |
| Main window: Devices | Every device seen, present ones leading, with trust and behavior tier. |
| Device inspector (pane) | Everything about one device: roles, topology, history, scans, and the trust control. |
| Main window: Settings | Permissions, scanner, protection, all state-legible. |
| Onboarding window (first run only) | The permission walk, one step per grant, skippable. |
| macOS notification | One alert, one sentence, tapping opens its expanded timeline row. |
| MCP face | The agent's complete peer surface (block below, contract in 03). |

Nine surfaces, four of them panes of one window. Nothing else. A quarantine browser was considered
and cut: quarantine records render inside scan records in the inspector, and a dedicated browser
is speculative until dogfooding proves the need (canon: kill speculative surfaces; noted in 09).

## Surface blocks

### Menu-bar glyph

| Field | Content |
|---|---|
| Purpose | Attention state at a glance. |
| Primary action | Click opens the popover. That is all it does. |
| Content leads | The glyph itself: idle (monochrome), degraded (monochrome with a dot), alert (tinted with the semantic warning/critical palette, never the brand accent), stopped (hollow outline). The four states differ in form, not only tint. Precedence when states coincide: stopped > alert > degraded > idle; an alert while degraded shows the alert (attention outranks health), and the popover then carries both facts. |
| States | The four above, made exclusive by the precedence rule. During daemon startup the glyph shows stopped-hollow until the first heartbeat, so it never claims monitoring that is not yet running. Empty state impossible (glyph always renders). |
| Deferred | Everything; the glyph holds zero text. |
| Error UI | Stopped shape covers daemon-down (9a). |
| Decision points | 1 (click or not). |

### Popover

| Field | Content |
|---|---|
| Purpose | Triage in three seconds without opening the window. |
| Primary action | Open Plugsight (the window), top-right. In every state, this remains the one primary; footer actions are inline links, subordinate by placement and weight. |
| Content leads | Active alerts first (if any), then the last five events as one-line sentences, then a one-line status footer. Config: none here, ever. |
| States | Loading: skeleton rows matching layout. Empty (no events yet): "Monitoring. Nothing has plugged in yet." plus the status footer; the empty sentence is checked against the same predicate as the list. Degraded: footer states the missing grant with one inline Grant link (1b, 1e). Stopped: single message + Start monitoring, which temporarily replaces the primary since the window has nothing to show (9a). Store error: the same what/why/one-action shape as the window surfaces ("Can't read the event record" + Reopen). At-scale: alerts cap at three with an "and 2 more" link opening the window filtered; events stay at five. |
| Deferred | All history, all detail, all settings: one click to the window. Alert handling defers to the alert's expanded timeline row. |
| Error UI | Alert rows carry severity icon + text; footer carries degraded/stopped reasons with their one action; store error as above. |
| Decision points | Max 3 visible: alert rows each carry only Details; everything else lives on the alert surface itself (the expanded timeline row). |

### Timeline (main window section)

| Field | Content |
|---|---|
| Purpose | Answer "what happened" for any time range, readably; expanded rows are the canonical alert surface. |
| Primary action | Per row: click to expand the explanation inline (why + suggested actions). For alert rows the expansion carries the alert's actions: Details is already spent, so the expansion shows Acknowledge as its primary and the trust shortcuts in an overflow, identical in behavior to the inspector's control. |
| Content leads | Event rows, newest first, grouped under day headers. Filters are one row of compact chips: a searchable device picker (never a flat list of 20), one severity chip, one kind chip. An "Alerts" chip toggles between active-only and all, which is where acknowledged and resolved alerts are found again. |
| States | Loading: skeleton rows. Empty with no filters: "No events yet. Plug something in and it will appear here." Empty with filters active: "No events match these filters" + Clear filters. Error (store unreadable): what happened, why, Reopen action. At-scale: virtualized list; day groups collapse; monitoring-gap rows render inline ("Monitoring was off 02:14 to 08:03") so absence of data is data (7a). |
| Deferred | Raw detail payloads behind the inline expansion; export lives in the window toolbar overflow. |
| Error UI | Expanded alert rows show the three-question shape (what, why, one recovering action). |
| Decision points | Chips (1 point, <= 5 chips, device picker searches) + row expansion (1 point) + chrome incl. the toolbar overflow (1 point). 3 total. |

### Devices (main window section)

| Field | Content |
|---|---|
| Purpose | Inventory with judgment attached: what is here, what has been here, what do I think of it. |
| Primary action | Select a row: opens the inspector pane. |
| Content leads | Present devices first, sorted by last activity; historical below, collapsed by default. Row: name, plain-language roles, trust badge, and a quiet behavior tier word (elevated / high) only when at notice level or above; the exact number lives in the tooltip and the inspector (an all-clear state gets no chip and no color). A device mid-scan shows a quiet "Scanning..." status text on its row. |
| States | Loading: skeleton. Empty: "Nothing has been plugged in since installation." (deliberately action-free: a monitor's empty state needs no task; ruling recorded in 09). At-scale (7b): rows stay 44 pt, present section sorts by activity, search field appears at > 10 devices, historical stays collapsed. Error: same store-error shape as Timeline. |
| Deferred | Interface tables, topology, history: inspector pane. |
| Error UI | A device with junk descriptors renders the plain fallback name (2b). |
| Decision points | List (1) + sort/search (1) + chrome (1). 3. |

### Device inspector (pane)

| Field | Content |
|---|---|
| Purpose | The full dossier for one device, decisions included. |
| Primary action | The trust control: one segmented control (Trusted / Default / Muted / Flagged), current tier always visible, the selected segment's one-line consequence rendered as its caption. Change applies immediately with an undo toast; the first-ever trust action shows the one-time forgeability note (6a). |
| Content leads | Identity header: name, roles in words, VID:PID and serial quiet below, and for storage devices the header carries Eject. Then the Behavior card: the number, tier word, and a disclosure holding the per-signal breakdown, the meaning line, and the caveat. Then interfaces (role word leading, raw codes as real tooltips), then this device's timeline, then scan records. Scan records hold the per-file verdicts and the quarantine entries, each with Restore, plus Retry on failed and Cancel on running scans. |
| States | Loading: skeleton per card. Behavior card, sensor off: "Typing observation is off (Input Monitoring not granted)" as a muted state with no number, linking the Settings row (4b). Sensor on, no data: "No typing observed from this device", muted, no number. Absent device: header states "not connected, last seen X"; trust control stays active (6c). Running scan: progress in the scan record with Cancel (5d). At-scale: its timeline paginates. |
| Deferred | Raw descriptor bytes behind a disclosure, rendered as a wrapped fixed-width block inside the pane (contained, no horizontal scroll). |
| Error UI | Trust write failure: inline, value preserved, retry action (a failed action never destroys input). Failed scan: reason + Retry (5f). |
| Decision points | Trust control (1, four options) + Behavior disclosure (1) + interfaces/raw disclosure (1) + scan record actions (1) + chrome (1). 5. |

### Settings (main window section)

| Field | Content |
|---|---|
| Purpose | Permissions, scanner, and protection, each row self-explanatory in its current state. |
| Primary action | Per-row; no global save (edit in place, applies immediately, owner-gated items confirm). |
| Content leads | Three groups. Permissions: Input Monitoring, System Extension, Full Disk Access; each row is state icon + what it enables in one sentence + Grant/Open action when missing. Scanner: engine found or the guided install step, definitions age ("2 days old"; "unknown" renders as its own muted state, stale age as a notice with the update command), scan-on-mount toggle. Protection: the "Hold new drives until scanned" toggle (one-line row copy; the full consequence paragraph lives in its confirm step) and the notification threshold picker with self-describing options. |
| States | Every row displays its own state inline. A disabled control always shows its reason as visible inline text, never hover-only (8b): "Needs the system extension; activate it above." |
| Deferred | Advanced scanner options (daemon socket path) behind one disclosure. |
| Error UI | A failed policy write restores the control to its true state and explains inline. |
| Decision points | Permissions (3 rows), Scanner (<= 4 controls), Protection (<= 3 controls). Each group is a decision point <= 7. |

### Onboarding window

| Field | Content |
|---|---|
| Purpose | Reach useful monitoring in under two minutes without lying about permissions. |
| Primary action | One per step: Grant (or Activate), with Skip always visible and never punished. |
| Content leads | The journey is shown end to end (canon: show the journey): four labeled steps (Welcome, Input Monitoring, System Extension, Scanner) with current position. The Welcome headline is the product in one read: "Plugsight shows you what your USB devices actually do." with the sub-line "It watches, explains, and never pretends to block." Each permission step says in two sentences what turns on and what stays off if skipped. |
| States | Each grant step live-updates when the grant lands (poll TCC state), on a fixed layout (the step card never changes height). "Waiting for System Settings" is an explicit state with a Try again. The location check (1d) renders its move instruction inside the extension step before activation. Completion states the resulting mode honestly, including degraded; skipped-everything completion: "Monitoring device connections only" with the Settings path named. |
| Deferred | Everything else in the app. |
| Error UI | A denied grant renders the degraded consequence inline with the deep link (1b/1c); never a blocking wall. |
| Decision points | 2 per step (primary + skip). |

### macOS notification

One sentence, the alert summary, severity in the words, not in decoration. Tap opens the alert's
expanded timeline row. No actions in the notification itself in v1 (they would duplicate the
alert surface for marginal gain; cut, noted in 09). At-scale rule: at most one notification per
device per five minutes; further alerts in the window coalesce into one summary notification
("3 alerts on 2 devices") so a chatty attack cannot bury the first warning or flood the user.

### MCP face

| Field | Content |
|---|---|
| Purpose | The agent's complete peer surface; contract in 03. |
| Primary action | n/a (tools, not chrome); the closest analog is that every read tool's output ends in facts and every error names its recovery, so the agent always has a next move. |
| Content leads | Tool results lead with the same summary sentences the UI shows; structured JSON rides along (03). |
| States | Healthy: normal results. Daemon down: `daemon_unreachable` with the literal human fix on every tool (9b). Version mismatch: refusal at startup naming both versions. Degraded daemon: `get_status` states which capability is off and what that disables; score tools return the sensor-off explanation, never a number (4b). Long-poll timeout: empty result + fresh cursor, by design. Pagination exhaustion: `nextCursor: null`, never an error. |
| Deferred | n/a. |
| Error UI | The error taxonomy of 02 (`kind` + human message + recovery), verbatim. |
| Decision points | n/a; the parity table below is this face's completeness check. |

## Row-to-path table

| Matrix row | Path (surfaces traversed) |
|---|---|
| 1a-1d | Onboarding window (-> System Settings and back) -> glyph |
| 1e | glyph (degraded) -> Popover footer -> Settings (Permissions) |
| 2a, 2b | glyph -> Popover |
| 2c, 3c, 4c, 5e, 6b, 7c, 8c, 9b | MCP face (tools named per row) |
| 3a | Notification -> Timeline (expanded alert row) -> overflow trust action or Device inspector |
| 3b | Timeline (quiet row) only |
| 4a | Notification -> Timeline (expanded alert row) |
| 4b | Popover footer / Settings (Permissions) / inspector Behavior card sensor-off state |
| 5a | Timeline only |
| 5b, 5g | Notification -> Timeline (expanded alert row) -> inspector scan record (Restore / Eject) |
| 5c | Timeline (skip event) -> Settings (Scanner) |
| 5d | Devices row ("Scanning...") -> inspector scan record (progress, Cancel) |
| 5f | Timeline (notice) -> inspector scan record (Retry) |
| 6a, 6c | Devices -> inspector (trust control) |
| 7a, 7b | Timeline (filters, gap rows) |
| 8a, 8b | Settings (Protection) |
| 9a | glyph (stopped) -> Popover (Start monitoring) |

No row is pathless. No surface is rowless.

### Tool-to-GUI parity table

The Tier 1 parity rule needs the reverse mapping too: every MCP tool reachable from the GUI, or
declared agent-only with a rationale; every GUI action naming its tool.

| Tool | GUI path |
|---|---|
| `get_status` | glyph + popover footer + Settings permission rows |
| `list_devices` / `get_device` | Devices list / inspector |
| `get_timeline` / `explain_event` | Timeline / expanded row |
| `tail_events` | the live-updating popover and timeline (same event stream) |
| `score_device` | inspector Behavior card |
| `list_alerts` | popover alerts + Timeline Alerts chip |
| `acknowledge_alert` | expanded alert row, Acknowledge |
| `trust_device` / `mute_device` / `flag_device` / `clear_device_mark` | inspector trust control (four segments) |
| `scan_storage` / `cancel_scan` / `get_scan` | inspector scan records (start via device overflow, Cancel, records) |
| `get_policy` / `set_policy` | Settings |

GUI actions with no tool: Eject (declared GUI-only: ejecting a volume is a standard OS operation,
not a Plugsight capability; an agent uses its ordinary shell access) and Restore-from-quarantine
(agent parity deferred to 09: restoring attacker-adjacent files is a deliberately human-gated act
in v1, and that gating is recorded as a decision, not an accident).

## Canon check

A fresh-eyes reviewer was dispatched on the first draft of this document with only the draft and
the design canon (never the reasoning behind it). It returned 61 findings: 20 FAIL, the rest RISK
or PASS. All FAIL findings are folded into the version above. The substantive resolutions:

1. **One trust interaction everywhere**: the segmented control with immediate apply + undo is the
   single pattern; alert overflows invoke the same behavior; the confirm sheet was cut and the
   forgeability caveat became a one-time first-use note. Tier `none` displays as Default in both
   faces; every tier carries a shared one-line consequence (this also fixed "Flag and Muted have
   undefined meaning", the reviewer's highest-value finding).
2. **The phantom alert surface**: alerts now have one canonical rendering, the expanded timeline
   row; all other appearances are echoes that lead there.
3. **Jargon purged from screens**: "mount-hold" became "Hold new drives until scanned"; IOKit/ES
   never render; "Unnamed keyboard" replaced the class-taxonomy fallback; the score is labeled
   Behavior with its meaning in a tooltip (which also cured the progressive-disclosure violation
   of a permanently stacked meaning line).
4. **Missing paths added**: scan `failed` with Retry (5f), quarantine-move failure (5g), Restore
   from quarantine (forgiveness), Eject given a home (inspector header), permission revocation
   mid-life (1e), the alert lifecycle's acknowledged/resolved states findable via the Timeline
   Alerts chip.
5. **Data honesty**: the sensor-off score state now says the sensor is off instead of "no typing
   observed"; the glyph claims stopped, not idle, during startup; the two timeline empty states
   split by filter predicate.
6. **State completeness**: the MCP face got a full surface block; the glyph got a state-precedence
   rule; the popover got a store-error state; notifications got a coalescing rule; the device
   picker searches at scale instead of offering 20 flat choices.
7. **Color discipline**: the glyph's alert state uses the semantic palette, never the brand
   accent; the devices row shows a quiet tier word, with the number in the tooltip.

Two findings were genuine rule conflicts and are recorded in 09 for an owner ruling with the
interim decision stated: action-free empty states on a monitor (chosen: allowed, with rationale),
and inline text vs hover for disabled-control reasons (chosen: inline text, the accessible side).

Not judgeable on paper, listed as build acceptance gates (07 wires them into N10/N11): Tier 1
contrast and axe gates, the humanizer pass over every shipped string, the parity check over all
tools, Tier 2 rhythm/type/color/interaction/forms/states/motion lints, dark/light parity on all
nine surfaces including both menu-bar appearances, at-scale screenshots with 20 seeded devices,
tabular-nums on all figures, real tooltips (`aria-describedby`) for the two places this design
depends on them, and the runtime data-honesty checks (empty-state predicates, null-not-zero
rendering). "Density survives mobile" and "Primary CTA above the fold" do not apply to a Mac
menu-bar app; recorded as deliberate n/a rather than silent skips.
