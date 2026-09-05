# 04. UX: stories, architecture, surfaces

Rewritten 2026-08-31 for the app UX overhaul (owner decisions D-blocking, D-shape, D-notify,
D-phasing in 10). Produced with the ux-architect method: FRAME with a derived-vs-invented ledger,
the full story matrix built around the S1-S10 core loop, the verdict and notification models, the
object model and navigation, the surface inventory with complete state sets, and the
row-to-path completeness check. The design canon and the Honesty Charter (00) govern throughout.
Error rows cite their confirmed cause in today's code (file:line from the 2026-08-31 audit) or an
existing spec section, so every error path is grounded in an observed failure, not a guess.

## FRAME

1. **Goal**: "I plug something in and I know, without studying anything, whether it is safe; when
   it is not, I see what is wrong and the one thing to do about it." (derived: 00 + owner ruling
   2026-08-31)
2. **Who runs it**: both. A human in the menu-bar app, and an agent over MCP. Peers over one API.
   (derived: brief)
3. **Trigger and end state**: triggered by a device event or by curiosity/suspicion; closed when
   the user or agent has seen the verdict and either acted on its one recommendation or decided
   nothing is needed. (derived: 00; the "or nothing" close stands from the first edition)
4. **Success, observably**: a first-time user can answer "is this device safe" for any listed
   device from its row alone; a yellow or red device names what is wrong and one working action;
   an unsafe device produces a notification within seconds; an agent reproduces all of it from
   tool calls. (derived: canon + owner ruling)
5. **Out of scope**: blocking beyond the mount-hold path (keystroke injection cannot be blocked
   on macOS: there is no HID veto, so detection plus an instant alert is the ceiling and every
   surface says so); fleet views; multi-machine anything; historical analytics dashboards; full
   localization (v1.x ships English-only with locale-correct dates and times; flagged as a
   follow-up, not silently dropped). (derived: 00 non-goals + D-blocking + explicit cuts)

### Personas

- **Maya**, an individual Mac user with reasons to care (journalist, developer, frequent
  traveler). Not a security professional. Reads verdicts, acts on the one recommendation, moves
  on. (invented, but constrained by 00's "personal tool" scope)
- **The operating agent**: Claude or a peer, connected over MCP, asked things like "anything
  plug in while I was away?" or standing watch during a talk. It needs machine-shaped facts and
  the same plain-language summaries, and its actions must be visible to Maya afterward. (derived:
  brief, agent-first)
- **The owner-operator** (dogfooding case): technical, checks Activity after an incident or a
  conference, tunes policy once and forgets it. (derived: 08 dogfooding)

## Shared vocabulary (both faces, same words)

- **Safety status** is the primary judgment word on every device, drawn from a fixed set of four:
  **Safe** (green), **Needs attention** (yellow), **Unsafe** (red), **Not checked** (grey). The
  full model is in the verdict section below. These four words are the vocabulary; surfaces never
  coin synonyms ("at risk", "suspicious", "unknown") for the same states.
- **Trust tiers** are `trusted`, `muted`, `flagged`, and `none` on the wire (05 defines their
  detection effects). The display word for `none` is **Default**. The control renders as "Alerts
  from this device" with a one-line consequence per tier, written once and rendered by both
  faces: Trusted "routine alerts off for this device; a critical finding still alerts"; Default
  "normal alerting"; Muted "no notifications from this device; everything still recorded";
  Flagged "every event from this device notifies, and it leads lists".
- **Alert lifecycle**: `active` (needs eyes), `acknowledged` (a person or agent saw it),
  `resolved` (the condition ended: the device detached, a rescan came back clean; set by the
  system, recorded with a reason). Alerts feed the safety status; they are not a separate primary
  surface.
- **Severity** (info < notice < warning < critical) survives on the wire and in Activity rows,
  but no user-facing control asks the user to pick a severity threshold any more (D-notify
  deleted it). Notification policy is the switch and checkbox below.
- **Score** renders under the label **Behavior** inside a verdict's reasons ("typing from this
  device looks automated"), demoted from a primary element to part of the why. The number and
  per-signal breakdown live in a disclosure in the device inspector.
- Degraded-mode copy names user-recognizable things only: "Input Monitoring", "the system
  extension", "the scanner", "notifications". Internal names (IOKit, ES, clamd,
  UNUserNotificationCenter) never reach a screen; they survive as tooltip detail.

## The verdict model: per-device safety status

New in this edition (Wave 2 builds it). Every device carries one derived **SafetyStatus**,
computed in core and exposed identically to the app and to MCP (`list_devices` / `get_device`).

| Status | Word | Derivation (core rule) | Presentation |
|---|---|---|---|
| green | Safe | Last scan clean (where scannable) AND no active alerts AND behavior low | Quiet green check icon + "Safe". No chip, no tint wash; silence is the success signal. |
| yellow | Needs attention | Any warning-grade condition: scan failed, definitions stale, elevated behavior, unacknowledged warning alert | Yellow triangle icon + "Needs attention" + reasons list. |
| red | Unsafe | Infected file found, critical alert, high behavior score | Red octagon icon + "Unsafe" + reasons list. Red is reserved for real danger, never for missing information. |
| grey | Not checked | Never scanned or scored: scanner missing, permission missing, not yet checked | Grey circle icon + "Not checked" + the reason it could not be checked. Grey is not red: zero information never renders as danger (Honesty Charter). |

Presentation rules, binding on every surface:

- **Icon plus word, never color alone.** Every status renders its icon and its word; the icon
  silhouettes differ (check / triangle / octagon / circle) so the states survive monochrome and
  VoiceOver reads the word. This extends the PSSeverityDot silhouette-plus-label pattern.
- **Reasons are a list; recommendations are singular.** A yellow or red status carries one or
  more reasons, each a plain-language sentence from a fixed vocabulary, and **each reason carries
  exactly one recommended action** (examples: "Scan failed: the volume could not be read." with
  Retry scan; "A file was quarantined." with Review the scan record; "Typing from this device
  looks automated." with Unplug it now). Never two competing buttons per reason.
- **The dormant-implant caveat is part of the vocabulary.** "Safe" copy is scoped honestly:
  a clean scan and quiet behavior cannot prove a device will never misbehave. The caveat sentence
  ("A device can turn hostile later; Plugsight keeps watching.") ships once per surface where
  "Safe" is explained (inspector verdict headline tooltip, MCP status payload), not stacked on
  every row.
- **No blocking language.** No status or recommendation implies Plugsight stopped anything,
  except the mount-hold flow while the ES extension is genuinely active (D-blocking).

## The notification model

New in this edition (Wave 2 builds it; today the app contains zero notification code, confirmed
by audit: no UserNotifications import anywhere in App/ or Sources/).

- **Delivery**: `UNUserNotificationCenter` banners from the app, driven by the daemon's existing
  `tail_events` stream (already implemented in `LiveAPIClient`, today uncalled by the live app).
- **Policy**: exactly two keys, replacing the deleted 3-level `notificationThreshold`:
  - `notifyUnsafe` (switch, "Notify me when a device looks unsafe", default on): fires on any
    device entering yellow or red.
  - `notifyNewDevice` (checkbox, "Also when any new device plugs in", default off): fires on
    every first attach of a device.
  - Migration: existing `notificationThreshold` values map to `notifyUnsafe: true` (any prior
    threshold) and `notifyNewDevice: true` only for the prior "Everything" setting; the old key
    is then removed.
- **Content**: one sentence naming the device and the leading reason, plus the one recommended
  action in words. Tapping opens the main window at that device.
- **Coalescing**: at most one notification per device per five minutes; further alerts inside
  the window coalesce into one summary ("3 alerts on 2 devices") so a chatty attack cannot bury
  the first warning.
- **Degraded state is visible**: when the user has denied notification permission, the promise
  "you will be notified" cannot be kept, and the app must say so: the Settings notifications
  section shows "Notifications are off for Plugsight in System Settings" with numbered steps to
  the exact pane, and the Devices home shows a quiet standing notice while `notifyUnsafe` is on
  but delivery is impossible. Never silent failure.

## Story matrix

The core loop S1-S10, in the user's own words, one story per band, happy plus error rows each.
Error-path causes cite the confirmed defect in today's code (audit 2026-08-31, file:line) or a
spec section; the Expected column states the required behaviour after the rebuild.

| # | Story | Actor | Path | Expected behaviour | Recovery | End state | Acceptance |
|---|---|---|---|---|---|---|---|
| S1a | I plug something in and see whether it is safe without opening anything | Maya | happy | Glyph updates; if the device is yellow/red (and `notifyUnsafe` on) or `notifyNewDevice` is on, a banner names the device, the leading reason, and the one action | - | Verdict known from the banner or glyph alone | Banner lands within one poll interval of the verdict; content is one sentence + one action |
| S1b | Same | Maya | error: notification permission denied (cause: no notification code exists at all today; audit, zero UserNotifications hits) | Visible degraded state: Settings notifications section and a quiet Devices-home notice say delivery is off and how to fix it | Numbered steps to the Notifications pane | Honest degraded promise | The denied state renders in Settings and on the Devices home; no surface claims "you will be notified" while it cannot happen |
| S1c | Same | Maya | edge: alert storm from one device | Coalescing: max one notification per device per 5 minutes; overflow becomes one summary banner | - | First warning stays visible | A scripted 10-alert burst yields at most 1 device banner + 1 summary in 5 minutes |
| S1d | Same | agent | happy | `tail_events` carries the attach and verdict-change events with the same summary sentences | - | Agent reports to its user | Event JSON summary equals the banner sentence |
| S2a | I open the app and see every device with its status, last scan, and last check time | Maya | happy | Devices home lists present devices first: name, status icon + word, "Scanned 14:32" / "Checking..." / "Not checked", real search, alert badge | - | Whole fleet judged at a glance | Every row answers safe-or-not without opening the inspector |
| S2b | Same | Maya | error: a device's scan history shows every device's scans (cause: app sends flat `deviceId`, daemon reads `filter.deviceId`; LiveAPIClient.swift:189 vs Router.swift:581) | Scans are filtered per device end to end | - | Each device shows only its own scans | Two devices with distinct scan histories render disjoint scan lists |
| S2c | Same | Maya | edge: scan in progress (cause: `DeviceSummaryDTO.scanning` has no daemon counterpart, so "Scanning..." never shows today) | Daemon exposes scanning + lastScan + activeAlerts on DeviceSummary; the row shows "Checking..." live | - | Progress visible from the home | A mounted volume mid-scan shows "Checking..." on its row within one poll |
| S2d | Same | Maya | edge: device never checked (scanner or permission missing) | Grey "Not checked" with the reason; never red, never blank (Honesty Charter: zero information is not danger) | Fix path in Settings | Honest grey state | No grey device ever renders red or "Safe" |
| S2e | Same | agent | happy | `list_devices` / `get_device` carry `safetyStatus` with status, reasons[], recommendation per reason | - | Agent reproduces the home view | Status word and reasons in the tool payload equal the row and inspector rendering |
| S3a | A device needs attention: I see what is wrong, why, and one action that works | Maya | happy | Inspector verdict headline "Needs attention" / "Unsafe" + reasons list, each with exactly one working action button (Scan again, Review scan record, Unplug advice, Hold when available) | - | Reason understood, action taken | Every rendered action button performs its action; none is decorative |
| S3b | Same | Maya | error: scan failed (cause today: failure reason discarded and Retry dead; DeviceInspectorViewModel.swift:138-141, DeviceInspectorView.swift:209) | Scan record shows `failed` with its reason (from `ScanSummary`) and a Retry that starts a real rescan | Retry scan | Failure legible, retryable | `failed` never renders as clean; Retry produces a new running scan |
| S3c | Same | Maya | error: scanner not installed (04 first edition 5c; Settings scanner row) | Reason "Could not check: no scanner installed" with the guided install step as its one action | Install via Settings scanner section | Scans resume next mount | The skip is a visible event and a grey/yellow reason, never silence |
| S3d | Same | Maya | error: permission missing (cause today: "Turn on Input Monitoring" button is dead; DeviceInspectorView.swift:157) | Reason names the missing grant; its one action opens the exact System Settings pane with numbered steps | Grant, row updates live | Degraded honestly labeled, recoverable | The action opens the correct pane; status refreshes without app restart |
| S3e | Same | agent | happy | `get_device` reasons carry machine-readable recommendation ids naming tools where one exists (`scan_storage`, `restore_quarantine`) | - | Agent acts or relays | Each recommendation that has a tool names it in the payload |
| S4a | A device is safe: quiet confirmation, no noise | Maya | happy | "Scanned and safe" + local time on the row and inspector headline; quiet green check; no chip stack, no color wash | - | Calm confirmed | An all-clear device shows exactly one status icon + word + time, nothing else colored |
| S4b | Same | Maya | error: times wrong or unreadable (cause today: UTC strings sliced and shown as local, 2h off on CEST, TimelineViewModel.swift:90; lastSeen rendered as raw ISO, DeviceInspectorViewModel.swift:35) | All timestamps parsed and rendered in the user's locale and timezone ("Scanned 14:32", "last seen yesterday 09:12") | - | Times trustworthy | No surface renders a raw ISO string or a silently shifted time |
| S5a | Something injects keystrokes: I am told within seconds what and what to do | Maya | happy | Notification names the device and says what happened ("started typing 0.4 s after plug-in") with the one action: unplug it now; glyph goes to alert state | - | User unplugs or decides | Banner within 5 s of the qualifying burst; copy claims detection, never blocking (D-blocking) |
| S5b | Same | Maya | edge: tuning via trust | "Alerts from this device" control (Trusted / Default / Muted / Flagged) with the shared consequence lines; behind a disclosure in the inspector | Set back to Default | Alerting tuned knowingly | Each tier change shows its consequence line before or as it applies |
| S5c | Same | Maya | error: false positive from the built-in keyboard (cause: typing on the internal keyboard is attributable to a fresh external device; audit scorer-misattribution defect) | Confidence downgraded when input activity is plausibly from another keyboard; the reason says "typing may be from another keyboard" instead of a hard verdict | Acknowledge; rescan behavior | No false "Unsafe" from own typing | The misattribution case renders yellow at most, with the uncertainty stated |
| S5d | Same | Maya | error: Input Monitoring off (cause today: status is a boot-time snapshot, never re-probed; audit defect) | Status re-checked on every status call; no behavior verdict claimed while the sensor is off; surfaces show the sensor-off explanation (never "no typing observed") | Grant from Settings | Honest degraded coverage | Revoking the grant mid-run flips the surfaces within a minute without restart |
| S6a | A new drive mounts: auto-scan starts, I can watch and cancel | Maya | happy | Scan starts on mount; progress visible on the row and in the scan record (cause today: progress hardcoded nil, DeviceInspectorViewModel.swift:139; Cancel dead, DeviceInspectorView.swift:208); Cancel works and records `canceled` | Cancel scan | Scan observed or canceled honestly | Progress moves; canceled scans record "canceled", never "clean" |
| S6b | Same | Maya | happy (hold path, ES extension active; ships dark until the Apple entitlement, D-blocking) | The drive is held until the scan finishes, then remounted; held state named on the row; `volume.held` / `volume.released` events emitted | Cancel releases the hold | Drive held only while actually held | Hold copy appears only while the extension is truly active; fail-open preserved |
| S6c | Same | Maya | error: daemon restarted mid-scan (cause today: stale `running` scans are never reconciled; audit defect) | On daemon start, orphaned running scans reconcile to `failed` with reason "interrupted" and a Retry | Retry scan | No immortal "running" rows | After a kill mid-scan, the record shows failed/interrupted, not running forever |
| S6d | Same | Maya | edge: trusted device skips the scan (cause today: the skip writes no record; audit defect) | A skipped-for-trust scan writes a visible record/event ("skipped: trusted device") | Scan manually if wanted | Absence of a scan is explained | The skip is queryable in Activity and the device's scan list |
| S7a | Setup: each permission row shows its state and the exact fix | Maya | happy | Settings shows the permission rows (Input Monitoring, the system extension; Full Disk Access was deliberately removed from the permission set, scanning works on /Volumes without it) with granted / not granted state; a not-granted row lists numbered steps naming the exact System Settings pane, and its button opens that pane | Grant, row updates live | All grants legible and reachable | Each row's deep link opens the named pane; state refreshes live |
| S7b | Same | Maya | error: system extension not available (cause today: the app can request activation of an extension that is not bundled, looping "Approve" forever; onboarding `bundledExtensionPresent` guard exists, Settings row lacks it) | The extension row is honest: when no extension is bundled it says so and offers no Approve; when activation fails, `lastActivationError` is surfaced in the row | Wait for a build that bundles it | No infinite approve loop | The row never asks the user to approve something that cannot activate |
| S7c | Same | Maya | edge: a granted permission is revoked later | Same degraded pattern as denial: glyph, Devices-home notice, and Settings row agree within a minute (needs S5d's live re-probe) | Re-grant from the row | Degraded state visible promptly | Revocation mid-life produces the identical UI as denial at setup |
| S8a | Settings answer themselves | Maya | happy | Scanner section in plain words: "Virus definitions: updated today. Plugsight updates them automatically."; a stale age becomes a notice with a working update action; every rendered control changes something | - | No dead or cryptic settings | Nothing rendered that cannot be changed; no "0 days old" phrasing |
| S8b | Same | Maya | error: notification picker inert (cause today: PSRadioGroup takes no callback, Controls.swift:84-107; the threshold UI is deleted per D-notify) | The switch (`notifyUnsafe`) and checkbox (`notifyNewDevice`) are real controls that persist through `set_policy`, with the migration from `notificationThreshold` | Toggle back | Policy actually changes | Toggling either control round-trips through the daemon and survives restart |
| S8c | Same | Maya | edge: hold toggle before the extension exists (cause today: the toggle is painted with no onToggle, SettingsView.swift:161-162) | The hold toggle is hidden entirely until the extension is truly available (bundled + activatable); once available it appears wired, disabled-with-reason when a prerequisite is missing | Activate extension first | No painted controls | While the extension is unavailable the toggle does not render at all |
| S8d | Same | agent | happy | `get_policy` / `set_policy` speak the two new keys; old `notificationThreshold` accepted read-only during migration, then gone | Retry with confirm | Policy parity | `set_policy` with `notifyUnsafe`/`notifyNewDevice` round-trips; threshold writes are rejected with the migration hint |
| S9a | The popover fits its content and never clips | Maya | happy | Popover sized to content up to a max height (cause today: 340x400 hardcoded twice, AppDelegate.swift:47 + PopoverView.swift:47, clipping the top); content view controller persists instead of being rebuilt every 5 s poll (AppDelegate.swift:51,114) | - | Popover readable in every state | No state clips; the VC updates in place |
| S9b | Same | Maya | happy: alerts lead somewhere | Popover alert rows' Details opens the main window at the right device; "and N more" opens the Devices home filtered (cause today: both dead, PopoverView.swift:117, :86) | - | Popover is a working front door | Details lands on the named device's inspector |
| S9c | Same | Maya | error: daemon down (04 first edition 9a) | Glyph shows stopped state; popover reduces to one message + Start monitoring, which really relaunches via SMAppService | Start monitoring | Monitoring resumes; gap recorded | Stopped is visually distinct from idle and degraded; the button works |
| S10a | History when I want it | Maya | happy | A quiet "Activity" link on the Devices home (not a sidebar tab, D-shape) opens the event history: day-grouped rows, localized day headers, local times, monitoring-gap rows kept | - | The record is there when wanted, invisible when not | Activity is reachable in one click from the home and absent from the sidebar |
| S10b | Same | Maya | error: filters and recovery decorative (cause today: filter chips and Alerts toggle are static, TimelineView.swift:24-27; Clear filters dead, TimelineView.swift:50; store-error Reopen dead, DesignTokens.swift:208) | Filters are real or absent (canvas decides which; nothing painted); Clear filters clears; the store-error Reopen reopens | Clear filters / Reopen | No decorative controls anywhere | Every control in Activity does what it says or does not render |
| S10c | Same | agent | happy | `get_timeline` unchanged: since/severity filters, cursor pagination; Activity is its GUI face (parity preserved despite the tab's deletion) | - | Agent summarizes history | Cursor pagination returns stable order across pages |

Dismissals (interrogated, no row): concurrent conflicting trust writes from both faces (last write
wins, both events recorded; the record is the resolution); offline (fully local product); in-app
auth boundary (single-user tool behind socket perms + token); a dedicated alerts section (alerts
feed the safety status and Activity; a fourth surface would duplicate them); localization overflow
(deferred per FRAME 5, structurally honored by not baking copy into fixed-width chrome, and the
fixed-height centre-clip pattern is removed repo-wide in the rebuild: OnboardingView.swift:66 is
the confirmed instance).

## Object model

| Object | Key fields | Relationships | Owner/scope |
|---|---|---|---|
| Device | name, vid/pid, serial, roles (plain-language), present, first/last seen, trust tier (+ consequence line), **safetyStatus** (status, reasons[], one recommendation per reason), scanning, lastScan, activeAlerts | has interfaces, events, alerts, scans | per machine |
| SafetyStatus | status (green/yellow/red/grey), reasons[] from the fixed vocabulary, recommendation per reason | derived on Device; identical over MCP | per device |
| Interface | class/subclass/protocol raw + role word | belongs to device | per device |
| Event | at, kind, severity, summary sentence, actor, detail | belongs to device (nullable for system events) | per machine |
| Alert | state (active / acknowledged / resolved), severity, why, suggested actions | groups events; feeds safetyStatus; belongs to device | per machine |
| Scan | state (running / clean / infected / failed / canceled / skipped), engine, startedAt/finishedAt, reason, verdicts, quarantine records | belongs to device + volume | per machine |
| Policy | scan on mount, hold new drives, **notifyUnsafe**, **notifyNewDevice**, scanner config | singleton | per machine |

Six nouns plus a singleton. The deleted field: `notificationThreshold` (D-notify, with
migration). The new noun, SafetyStatus, is derived state: it introduces no new storage, only a
computation both faces share.

## Navigation

One menu-bar item, one popover, one main window, plus OS-owned surfaces (notifications, System
Settings). Inside the main window: a sidebar with exactly **two** items, **Devices** and
**Settings** (D-shape). **Activity is a link**, not a tab: a quiet control on the Devices home
opens the event history view; it has no sidebar presence and no badge. Device detail opens as an
inspector pane inside the window, never a modal. Alerts have no section of their own: an alert
surfaces as reasons on its device's safety status and as rows in Activity; the notification and
the popover are echoes that open the main window at the device.

## Surface inventory

| Surface | Purpose (one sentence) |
|---|---|
| Menu-bar glyph | Show at a glance whether anything needs attention. |
| Popover | Triage in three seconds: worst statuses and last events, sized to its content. |
| Main window: Devices home | Every device with its safety status, last scan, and last check; the app's home. |
| Device inspector (pane) | One device's verdict, reasons, actions, history, scans, and the alerts control. |
| Activity view (link from Devices home) | The readable event history with monitoring-gap honesty; quiet, not a tab. |
| Main window: Settings | Permissions, scanner, notifications, protection, all state-legible and all real. |
| Onboarding window (first run only) | The permission walk, one step per grant, skippable, plus the notification permission ask. |
| macOS notification | One sentence, one device, one recommended action; tapping opens the device. |
| MCP face | The agent's complete peer surface (block below, contract in 03). |

Nine surfaces, three of them faces of one window. The Timeline tab is deleted (D-shape); its
value lives in the Activity link and per-device history. A quarantine browser stays cut
(quarantine records render inside scan records).

## Surface blocks

### Menu-bar glyph

| Field | Content |
|---|---|
| Purpose | Attention state at a glance. |
| Primary action | Click opens the popover. That is all it does. |
| Content leads | The glyph itself: idle (monochrome), degraded (monochrome with a dot), alert (tinted with the semantic palette, never the brand accent), stopped (hollow outline). The four states differ in form, not only tint. Precedence: stopped > alert > degraded > idle. The "all clear" rendering must be reachable without the ES extension: today it is not, because the daemon's all-present rule requires `endpointSecurity`, which the standalone daemon hardcodes false (Router.swift:146, plugsightd/main.swift:80); the rebuild keys "all clear" on the capabilities the install actually has. |
| States | The four above, made exclusive by precedence. During daemon startup the glyph shows stopped-hollow until the first heartbeat. Empty state impossible (glyph always renders). |
| Deferred | Everything; the glyph holds zero text. |
| Error UI | Stopped shape covers daemon-down (S9c). |
| Decision points | 1 (click or not). |

### Popover

| Field | Content |
|---|---|
| Purpose | Triage in three seconds without opening the window. |
| Primary action | Open Plugsight (the window), top-right; alert rows' Details opens the window at the device (S9b). |
| Content leads | Devices needing attention first (status icon + word + leading reason), then the last few events as one-line sentences, then a one-line status footer. Config: none here, ever. |
| States | Sized to content with a max height; no state may clip (S9a; the fixed 340x400 and the 5 s VC rebuild are removed). Loading: skeleton rows. Empty: "Monitoring. Nothing has plugged in yet." + status footer. Degraded: footer states the missing grant or the denied notification permission with one working link into Settings. Stopped: single message + working Start monitoring (S9c). Store error: what/why/one-action shape with a working Reopen. At-scale: attention list caps at three with a working "and N more" opening the Devices home. |
| Deferred | All history, detail, and settings: one click to the window. |
| Error UI | Status rows carry icon + word; footer carries degraded/stopped reasons with their one working action. |
| Decision points | Max 3 visible: rows carry only Details; everything else lives in the window. |

### Devices home (main window section)

| Field | Content |
|---|---|
| Purpose | Answer "is everything safe" for the whole fleet at a glance; the app's home. |
| Primary action | Select a row: opens the inspector pane. |
| Content leads | Present devices first, sorted by attention (red, yellow, grey, green) then last activity; historical below, collapsed. Row: device icon, name, status icon + word, "Scanned 14:32" / "Checking..." / "Not checked", active-alert badge when > 0 (today modelled but never rendered: DevicesViewModel.swift:22). A **real** search field filters by name/roles (today's field is painted text: DevicesView.swift:36-39). The quiet **Activity** link lives here (S10a). A standing notice renders while notifications are on but permission is denied (S1b). |
| States | Loading: skeleton. Empty: "Nothing has been plugged in since installation." (action-free by ruling, 09). At-scale: rows stay 44 pt, search always usable, historical stays collapsed. Error: shared store-error shape with a working Reopen. |
| Deferred | Reasons, history, scans: inspector pane. Event history: Activity link. |
| Error UI | A device with junk descriptors renders the plain fallback name ("Unnamed keyboard"). |
| Decision points | List (1) + search (1) + Activity link (1) + chrome (1). 4. |

### Device inspector (pane)

| Field | Content |
|---|---|
| Purpose | One device's full dossier: verdict first, decisions included. |
| Primary action | The verdict's recommended action(s): one working button per yellow/red reason (S3a). |
| Content leads | Verdict headline ("Scanned and safe" / "Needs attention" / "Unsafe" / "Not checked") with icon + word + local time, then the reasons list with one action each. Identity (name, roles, VID:PID and serial quiet below; Eject for storage, working). Then "Alerts from this device" (the trust control) behind a disclosure with consequence lines (S5b). Then Behavior details behind a disclosure (number, per-signal breakdown, caveat), then interfaces, then this device's history, then scan records with date/time + reason, capped with "Show all". Scan records hold per-file verdicts and quarantine entries with working Restore, Retry on failed, Cancel on running. |
| States | Loading: skeleton per card. Sensor off: "Typing observation is off (Input Monitoring not granted)", linking the Settings row, never a number (S5d). Absent device: "not connected, last seen <local time>" (parsed, not raw ISO; S4b); trust control stays active. Running scan: progress + Cancel (S6a). Scans area: always present for STORAGE devices (an empty scan list explains itself with "Not scanned yet" and a working Scan now); non-storage devices show no scans section at all (owner decision: no irrelevant fields). |
| Deferred | Raw descriptor bytes behind a disclosure, wrapped, contained. |
| Error UI | Failed scan: reason + working Retry (S3b). A failed trust write restores the control and explains inline. |
| Decision points | Recommended actions (1 per reason, singular each) + alerts-control disclosure (1) + behavior disclosure (1) + scan actions (1) + chrome (1). 5. |

### Activity view (link from Devices home)

| Field | Content |
|---|---|
| Purpose | Answer "what happened" for any time range, readably, when the user asks for it; deliberately quiet (D-shape). |
| Primary action | Per row: click to expand the explanation inline (why + the device link). |
| Content leads | Event rows, newest first, grouped under localized day headers with local times (today both are wrong: UTC string-sliced day keys, TimelineViewModel.swift:90, and mixed-language headers). Filters: real or absent per the picked canvas direction; whatever renders, works (S10b). Monitoring-gap rows render inline ("Monitoring was off 02:14 to 08:03") so absence of data is data. |
| States | Loading: skeleton rows. Empty, no filters: "No events yet. Plug something in and it will appear here." Empty with filters: "No events match these filters" + working Clear filters. Error: store-error shape with a working Reopen. At-scale: virtualized; day groups collapse. |
| Deferred | Raw detail payloads behind the inline expansion. |
| Error UI | Expanded rows show the what/why/one-action shape. |
| Decision points | Filters (1, if present) + row expansion (1) + chrome (1). <= 3. |

### Settings (main window section)

| Field | Content |
|---|---|
| Purpose | Permissions, scanner, notifications, protection; each row self-explanatory in its current state; nothing rendered that cannot be changed (S8a). |
| Primary action | Per-row; no global save. |
| Content leads | Four groups. **Permissions**: the Input Monitoring row (Full Disk Access was deliberately removed from the permission set; it is not used at runtime), with granted / not granted state; a not-granted row shows numbered steps naming the exact System Settings pane and a button that opens it (S7a); plus the **system extension row**, honest: hidden or plainly "not included in this build" when `bundledExtensionPresent` is false, and surfacing `lastActivationError` when activation fails (S7b). **Scanner**: plain words: "Virus definitions: updated today. Plugsight updates them automatically."; stale age is a notice with a working update action; engine missing shows the guided install step. **Notifications**: the switch "Notify me when a device looks unsafe" + checkbox "Also when any new device plugs in" (S8b), and the permission-denied degraded state with numbered steps when applicable (S1b). **Protection**: scan-on-mount toggle; the "Hold new drives until scanned" toggle is **hidden until the extension is truly available**, then rendered wired, disabled-with-inline-reason when a prerequisite is missing (S8c). |
| States | Every row displays its own state inline. A disabled control always shows its reason as visible inline text, never hover-only. |
| Deferred | Advanced scanner options behind one disclosure. |
| Error UI | A failed policy write restores the control to its true state and explains inline. |
| Decision points | Permissions (<= 3 rows), Scanner (<= 3 controls), Notifications (2 controls), Protection (<= 2 controls). Each group one decision point. |

### Onboarding window

| Field | Content |
|---|---|
| Purpose | Reach useful monitoring in under two minutes without lying about permissions. |
| Primary action | One per step: Grant (or Activate), with Skip always visible and never punished. |
| Content leads | The journey shown end to end: Welcome, Input Monitoring, System Extension (only when bundled), Scanner, **Notifications** (the UNUserNotificationCenter ask, new). Welcome headline: "Plugsight shows you what your USB devices actually do." with "It watches, explains, and never pretends to block." Each step says what turns on and what stays off if skipped. |
| States | Each grant step live-updates when the grant lands, on a layout that grows with its content: the fixed 320 pt card that centre-clips today (OnboardingView.swift:66) is removed with the repo-wide fixed-height pattern. "Waiting for System Settings" is explicit with Try again. Completion states the resulting mode honestly, including degraded. |
| Deferred | Everything else in the app. |
| Error UI | A denied grant renders the degraded consequence inline with the working deep link; never a blocking wall. |
| Decision points | 2 per step (primary + skip). |

### macOS notification

One sentence naming the device and the leading reason, plus the one recommended action in words;
severity lives in the words, not decoration. Tapping opens the main window at that device's
inspector. Policy is the switch + checkbox (D-notify); coalescing is the at-most-one-per-device-
per-five-minutes rule with the summary banner. When permission is denied, no code path pretends
to have notified: the degraded state renders in Settings and on the Devices home (S1b).

### MCP face

| Field | Content |
|---|---|
| Purpose | The agent's complete peer surface; contract in 03. |
| Primary action | n/a (tools, not chrome); every read tool's output ends in facts and every error names its recovery. |
| Content leads | Tool results lead with the same summary sentences the UI shows; structured JSON rides along (03). `list_devices` / `get_device` now carry `safetyStatus` (status, reasons[], one recommendation per reason), identical to the GUI derivation. |
| States | Healthy: normal results. Daemon down: `daemon_unreachable` with the literal human fix on every tool. Version mismatch: refusal at startup naming both versions. Degraded daemon: `get_status` states which capability is off; score tools return the sensor-off explanation, never a number. Long-poll timeout: empty result + fresh cursor. Pagination exhaustion: `nextCursor: null`, never an error. |
| Deferred | n/a. |
| Error UI | The error taxonomy of 02 (`kind` + human message + recovery), verbatim. |
| Decision points | n/a; the parity table below is this face's completeness check. |

## Row-to-path table

| Matrix row | Path (surfaces traversed) |
|---|---|
| S1a | glyph / macOS notification |
| S1b | Settings (Notifications) + Devices home notice |
| S1c | macOS notification (coalesced) |
| S1d, S2e, S3e, S8d, S10c | MCP face (tools named per row) |
| S2a-S2d | Devices home |
| S3a-S3d | Devices home -> inspector (verdict reasons + actions; Settings for S3c/S3d fixes) |
| S4a, S4b | Devices home row + inspector headline |
| S5a | macOS notification -> inspector |
| S5b | inspector ("Alerts from this device" disclosure) |
| S5c | inspector (uncertain reason) |
| S5d | Settings (Permissions) + inspector sensor-off state |
| S6a | Devices home ("Checking...") -> inspector scan record (progress, Cancel) |
| S6b | Devices home (held state) -> inspector; Settings (Protection) for the toggle |
| S6c | inspector scan record (failed/interrupted + Retry) |
| S6d | Activity (skip event) + inspector scan list |
| S7a-S7c | Settings (Permissions) (+ onboarding on first run) |
| S8a | Settings (Scanner) |
| S8b | Settings (Notifications) |
| S8c | Settings (Protection) |
| S9a-S9c | glyph -> Popover (-> main window at device) |
| S10a, S10b | Devices home -> Activity view |

No row is pathless. No surface is rowless.

### Tool-to-GUI parity table

Every MCP tool reachable from the GUI, or declared agent-only with a rationale; every GUI action
naming its tool. Deleting the Timeline tab deletes no capability: `get_timeline` keeps its GUI
face in the Activity view.

| Tool | GUI path |
|---|---|
| `get_status` | glyph + popover footer + Settings rows |
| `list_devices` / `get_device` | Devices home / inspector, **now including `safetyStatus`** (status icon + word, reasons, recommendations) |
| `get_timeline` / `explain_event` | Activity view (link from Devices home) / expanded row |
| `tail_events` | live updates on popover, Devices home, and Activity; also drives notification delivery |
| `score_device` | inspector Behavior disclosure (demoted into the verdict's why) |
| `list_alerts` | reasons on device rows/inspector + Activity rows |
| `acknowledge_alert` | inspector reason row acknowledge |
| `trust_device` / `mute_device` / `flag_device` / `clear_device_mark` | inspector "Alerts from this device" control |
| `scan_storage` / `cancel_scan` / `get_scan` | inspector scan records (Scan now / Cancel / records) |
| `restore_quarantine` | inspector scan record Restore (confirm-gated both faces, D6 in 10) |
| `get_policy` / `set_policy` | Settings (notifyUnsafe, notifyNewDevice, scan on mount, hold when available) |

GUI actions with no tool: Eject (standard OS operation, agent uses ordinary shell access) and
opening System Settings panes (OS navigation, not a Plugsight capability).

## Honesty constraints (binding, from 00 + D-blocking)

- **Detector, not blocker, on every surface.** No copy, control, status word, or tool text
  implies Plugsight blocked, stopped, or prevented anything, with exactly one exception: the
  mount-hold flow while the ES extension is genuinely active, which describes only what it
  actually does (hold a drive until its scan finishes). Until the Apple entitlement lands, the
  hold path ships dark: no toggle, no copy, no claim.
- **Keystroke injection is detected, never blocked**: macOS offers no HID veto. Alert copy says
  "started typing" and recommends unplugging; it never says "blocked".
- **The dormant-implant caveat** rides with every explanation of "Safe" (see verdict model).
- **Grey is not red**: a zero-information state (never scanned, scanner missing, permission
  missing) renders "Not checked" with its reason, never danger colors and never a blank.
- **Degraded states are visible**: any promise the app cannot currently keep (notifications
  denied, sensor off, daemon down) is stated where the promise is made.

## Canon check

The first edition's fresh-eyes canon review (61 findings, all FAILs folded in) shaped the
patterns this edition keeps: one trust interaction everywhere, jargon purged from screens,
data honesty in empty and sensor-off states, the coalescing rule, and color discipline. This
edition's changes (verdict model, notification model, Devices-home IA, Activity demotion) are
audited against the same canon by the Wave 5 fresh-eyes judge, which receives only the built
app's screenshots, this matrix, and the canon, and returns per-row verdicts; UNREACHABLE rows
(the S6b hold path until the entitlement) are named, not silently skipped. Current coverage of
every row, with today's defects as evidence, is tracked in `docs/ux/app-redesign-coverage.md`.

Build acceptance gates that are not judgeable on paper (07 wires them in): Tier 1 contrast and
axe gates on the new status colors (extending DesignTokens with AA-checked light/dark pairs; the
trust tint is defined once, not twice), the humanizer pass over every shipped string, the parity
check over all tools, dark/light parity on all surfaces including both menu-bar appearances,
at-scale screenshots with 20 seeded devices, tabular-nums on all figures, window
`contentMinSize` at or above the panes' own minimums with frame autosave (today the window opens
820 pt against an 841 pt minimum: AppDelegate.swift:182), and live refresh everywhere (no data
frozen after first open). "Density survives mobile" and "Primary CTA above the fold" remain
deliberate n/a for a Mac menu-bar app.
