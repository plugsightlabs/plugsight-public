# 05. Detection: HID scoring, class-mismatch rules, ClamAV

Three detection families, in decreasing order of certainty: class-mismatch rules (deterministic,
descriptor facts), behavioral HID scoring (probabilistic, timing facts), and storage scanning
(delegated to ClamAV signatures). Every threshold in this doc is a named constant in one Swift
file (`DetectionTuning.swift`) so tuning never hides in call sites, and every number below is a
starting value to be calibrated during dogfooding, not revealed truth.

## Stated up front, per the charter

Behavioral detection is probabilistic and evadable. A patient implant that waits before typing and
types at human cadence will score low. The mismatch rules do not depend on behavior, which is why
they are the strongest signal, but they only fire when the attacker chose a composite descriptor.
The product's claim is bounded: we raise the attacker's cost, we catch the common commercial
payloads as shipped, and we leave a legible record either way. All user-facing score copy carries
the caveat field (03).

## Class-mismatch rules

Run at enumeration time from interface descriptors alone. Deterministic: a rule either matches or
does not, and the alert quotes the facts ("presented as mass storage; also enumerated a keyboard
interface").

Vocabulary: interface class codes per the USB standard: HID 0x03 (keyboard when protocol 0x01 or
usage page confirms), mass storage 0x08, CDC 0x02 / CDC-data 0x0A (network when subclass is
ECM/NCM, or RNDIS), smartcard CCID 0x0B, vendor-specific 0xFF, billboard 0x11, hub 0x09, audio
0x01, video 0x0E.

| Rule | Condition | Severity | Rationale |
|---|---|---|---|
| R1 hidden keyboard | Device has storage, billboard, or vendor-only primary presentation AND a HID keyboard interface | critical | The BadUSB signature shape. A charger or stick has no business typing. |
| R2 hidden network | Non-network-presenting device also enumerates CDC ECM/NCM or RNDIS | critical | Covert network path (T3). |
| R3 keyboard plus network | HID keyboard and network interface on one device | critical | Classic implant combo, no consumer precedent. |
| R4 keyboard plus storage | HID keyboard and mass storage on one device | warning | Real implants do this; so do a few legit oddballs (keyboards with "driver CD" partitions). Warning, not critical, and the alert says why. |
| R5 late interface | Device re-enumerates with more interfaces than its first enumeration in this session | warning | Mode-switching after trust inspection is implant behavior; also matched by some legit modem sticks, hence warning. |
| R6 descriptor anomaly | Empty vendor and product strings on a HID keyboard device, or a serial that changes across attaches on otherwise identical descriptors | notice | Weak signal alone; feeds the score rather than alerting by itself. |

Legit-composite allowlist, checked before R1-R4 and shipped as data (not code) so updates need no
release: security keys (HID + CCID + vendor, the FIDO shape), keyboard-with-hub (keyboard + hub +
mouse), webcams (video + audio), docks and adapters that legitimately present hub + network +
audio + billboard. An allowlist hit downgrades the rule to an info event that names the pattern
("composite device matching the security-key shape"). The allowlist matches interface shapes,
never VID/PID, so a forged VID buys the attacker nothing here.

## Behavioral HID signals

Sources: a listen-only CGEventTap (keyboard event timestamps) plus IOHIDManager per-device input
callbacks, both under the one Input Monitoring grant (L4). The tap gives clean global timing;
the HID callbacks give device attribution. Where attribution is ambiguous (two keyboards typing in
the same window), the scorer says so in its confidence, never guesses silently. Timing metadata
only is stored (02).

A **device epoch** opens when a HID-capable device attaches and closes 120 s later (constant
`epochWindow`); behavioral signals evaluate keystrokes attributed to the new device, with the
epoch window bounding the plug-to-type signal.

| Signal | Id | Suspicious when (starting values) | Weight |
|---|---|---|---|
| Plug-to-type latency | `plug_to_type_latency` | First keystroke from the new device < 2000 ms after enumeration; < 500 ms is near-certain automation. Score contribution ramps linearly from 2000 ms (0.0) to 500 ms (1.0). | 0.35 |
| Inter-keystroke timing | `inter_key_timing` | Over a burst of >= 12 keystrokes: mean interval < 35 ms, or standard deviation < 12 ms regardless of mean. Humans average 80 to 200 ms with wide variance; commercial injectors ship near-uniform sub-30 ms cadence. Ramp on both mean and stddev, take the max. | 0.35 |
| Redundant keyboard | `redundant_keyboard` | A new keyboard-class device on a machine where the built-in or an already-present keyboard was active in the last 10 minutes. Binary 0/1. | 0.15 |
| Descriptor oddity | `descriptor_oddity` | R6 fired, or the device's declared HID report descriptor is the minimal boilerplate the common injector firmwares ship. Binary. | 0.15 |

Class-mismatch hits do not feed this score; they alert directly (stronger evidence should not be
laundered through a weaker average). The score is:

```
score = round(100 * (0.35*s_latency + 0.35*s_timing + 0.15*s_redundant + 0.15*s_oddity))
```

Confidence is a function of evidence volume and agreement, reported as low/medium/high:

- low: fewer than 12 attributed keystrokes, or attribution ambiguous
- medium: >= 12 keystrokes, single-signal dominance
- high: >= 30 keystrokes and at least two signals above 0.5

Alerting thresholds (policy-adjustable, these are defaults): score >= 60 with medium confidence
raises a warning alert; >= 85 with medium-or-high raises critical. Low confidence never alerts on
its own; it renders in the device inspector as an observation.

No machine learning in v1. The deterministic model is explainable line by line, which the
timeline requires, and we have no labeled corpus that would make a learned model anything but
theater. Revisit only with real dogfooding data (09).

## Trust tiers and their effect on detection

Defined once, used verbatim by 03 and 04:

- `trusted`: routine alerts (warning and below) suppressed for this device; events still recorded;
  critical still alerts. Trust raises the bar, it does not close the file, because identity is
  forgeable (L9).
- `muted`: no notifications at any severity; everything recorded; the device row shows the muted
  badge so silence is legible.
- `flagged`: every severity notifies, device leads worklists, and its epochs use the stricter
  flagged thresholds (alert at score >= 40).
- `none`: defaults above.

## Storage scanning (ClamAV orchestration)

Plugsight orchestrates ClamAV; it does not embed an engine and never claims scan quality beyond
ClamAV's. Discovery order at daemon start and on demand: a running `clamd` (socket from policy,
default the Homebrew path) used via `clamdscan`; else `clamscan` on PATH or the Homebrew
locations; else state `unavailable` with the install fix ("brew install clamav", then the
freshclam first-run step) surfaced in Settings and in any scan attempt error.

On mount of a volume from a USB device (DiskArbitration event, ES-confirmed when the extension is
active): if policy `scanOnMount` is true and the device is not `trusted`, start a scan. A scan is
a child process with a hard timeout (default 15 min, policy), streamed output parsed into per-file
verdicts. Exit code contract: 0 clean, 1 findings, 2 engine error (rendered as `failed`, never as
clean). Cancellation kills the process group and records `canceled`. Definitions age comes from
`freshclam`'s database timestamps; older than 7 days renders a notice in Settings and in scan
records ("definitions 12 days old"), because a scan with stale signatures should not read as full
strength.

Findings: the file is moved into the quarantine directory (02) when policy `quarantine` is true
(default true), with its sidecar; the alert names file, signature, and completed action. Moves
that fail (read-only volume) degrade to report-only and the alert says exactly that instead of
claiming containment.

The mount-hold option (`ES_EVENT_TYPE_AUTH_MOUNT`, policy `holdUntilScanned`, default off) is the
one enforcement point in the product: deny the initial mount, scan the raw volume via a private
remount, then remount user-visible on clean. Its UI prerequisites are specified in 04 (8a/8b);
its failure mode is fail-open with a logged event (02).

## Testing detection without a BadUSB device

The scorer consumes `AsyncStream<CollectorEvent>` (02's seam), so the test suite feeds synthetic
streams: recorded real-typing traces (fixtures captured from the developer's own machine via a
debug flag), synthetic injector traces (uniform 20 ms cadence, 300 ms after attach), and
adversarial traces (humanized cadence, delayed start) asserting both detection and honest
non-detection. The class-mismatch rules take plain descriptor structs; fixtures cover every rule
and every allowlist shape. A hardware smoke test with a real injector (any Digispark-class board)
is a manual release-checklist item, not CI. Details and gates in 07.
