# 01. Threat model

This document ranks what Plugsight actually defends against, states what it cannot touch, and pins
down the macOS platform limits that shape the whole design. Nothing in later docs may contradict
the limits table here.

## Assumptions

- The attacker has brief physical access to the machine or can hand the user a device (a "free"
  cable, a conference USB stick, a loaner charger).
- The machine is a single-user Mac running macOS 13 or later, administered by its owner.
- The user runs Plugsight with the permissions it requests during onboarding (Input Monitoring for
  the scorer, the system extension approval, Full Disk Access for scanning where needed).
- The attacker may know Plugsight is installed. A detector that only works in secret is not worth
  shipping, so evasion resistance is discussed per signal in 05.

Out of the model entirely: an attacker with root on the host (they can kill the daemon), supply
chain compromise of the OS, and attacks needing hardware we cannot observe (RF, DMA below the
IOMMU).

## Threats, ranked honestly

Ranked by (likelihood for an individual Mac user) times (what Plugsight can actually contribute).
This ranking drives UI priority and alert severity defaults.

### T1. Keystroke injection (BadUSB class)

A device enumerates as a HID keyboard and types a payload: Rubber Ducky and Bash Bunny style
implants, O.MG cables, flashed consumer sticks. This is the headline threat because it is cheap,
commercial, and effective, and because macOS gives third parties no way to block it (see limits).

Plugsight's contribution: detection within the first seconds. Three behavioral signals (plug-to-type
latency, inter-keystroke timing, redundant-keyboard presence) plus the class-mismatch check. An
alert lands while the payload is typing or seconds after. That is late for prevention and early for
response: the user knows what happened, what it typed into which app, and when. Detail in 05.

Honest limits: a patient implant that waits minutes and types at human cadence will beat the
behavioral score. The class-mismatch signal still fires if the device also claims storage or
network roles. A pure "keyboard only, slow typing" implant is the residual gap, and Apple's
accessory prompt (Apple Silicon laptops) is the only thing on the platform that stands in front of
it.

### T2. Malware on removable storage

The classic infected USB stick. Plugsight's contribution is orchestration and legibility: on mount,
a ClamAV scan runs, results land in the timeline as a plain sentence, and infected files can be
quarantined. ClamAV's signature coverage is what it is; we surface its verdicts, we do not improve
them. This threat also has the platform's only real authorization hook that works for us:
storage-class devices are opened from userspace, so the ES extension can hold or deny an open by
policy where the user turns that on.

### T3. Covert network interface

A device that also enumerates as a CDC-ECM/NCM or RNDIS network adapter and becomes a DHCP server
or DNS path (LAN Turtle style, and one of the classic O.MG modes). macOS will happily add the
interface. Plugsight flags the mismatch at enumeration time ("this 'charger' just added a network
adapter") and records whether the interface came up. We do not firewall it in v1; the alert is the
product.

### T4. Data exfiltration to mass storage

Someone (or something) copies data to an attached stick. Watching per-file writes at DLP fidelity
is out of scope for v1, and half-shipping DLP would be dishonest. What v1 records honestly: the
mount event, the device identity, and scan results. File-level auditing is a stated maybe in 09.

### T5. Juice jacking

Charging-port data attacks. In the threat folklore this ranks high; in reality there are no
credibly documented in-the-wild compromises of a modern, patched device, and the trust-prompt model
on iOS and macOS closed the classic vector years ago. We say this plainly in user-facing material.
It is not a headline threat and Plugsight does not market against it. Where it overlaps T1/T3 (a
"charger" that enumerates interfaces), the same detections apply.

### T6. Dormant implants

An O.MG cable that is not currently doing anything is electrically a cable. No host software can
see the implant. Plugsight's only honest contribution: the moment it wakes up and does something
observable, that action is captured and explained. The charter requires us to say this rather than
imply coverage.

## Platform limits (the facts the design is built on)

Every claim in this table is a hard constraint. Later docs cite these rows rather than restating
them.

| # | Fact | Consequence for Plugsight |
|---|---|---|
| L1 | IOKit device notifications (`IOServiceAddMatchingNotification`, first-match and terminated) are observational. There is no third-party veto point in device enumeration. | The collector is notify-only by construction, not by policy choice. |
| L2 | HID keyboards are matched and driven in-kernel by IOHIDFamily. Normal typing involves no userspace `IOServiceOpen` on the device. | `ES_EVENT_TYPE_AUTH_IOKIT_OPEN` never sees a HID keyboard doing its job. ES cannot block or gate HID input. Any design assuming otherwise is wrong. |
| L3 | `ES_EVENT_TYPE_AUTH_IOKIT_OPEN` does fire when a userspace process opens an IOKit service (storage-adjacent user clients, some vendor tools). ES also delivers mount/unmount events, with an AUTH variant for mounts. | The ES extension earns its keep on storage: it can observe device opens and can hold or deny mounts by policy. That is the honest extent of "blocking" in this product, and it is attributed to ES, not to magic. |
| L4 | A listen-only `CGEventTap` for keyboard events requires the Input Monitoring TCC permission (macOS 10.15 and later). Without the grant, the tap delivers nothing. | The HID scorer degrades to enumeration-only signals until the user grants Input Monitoring. Onboarding must treat this as the scorer's on switch and say what turns off without it. |
| L5 | The Endpoint Security client entitlement (`com.apple.developer.endpoint-security.client`) is granted by Apple on application, per developer account, with manual review. Development builds can run with SIP-relaxed machines; distribution cannot. | The ES extension is a separately shippable component. The product must be fully useful without it (collector + scorer + ClamAV path), or the entitlement wait blocks the whole release. |
| L6 | System extensions require explicit user approval in System Settings, and the app hosting the extension must be signed, notarized, and (in practice) run from /Applications. | Onboarding owns a real multi-step activation flow with OS-controlled UI we cannot restyle. Specified in 04. |
| L7 | Kernel extensions are effectively dead for third-party distribution: deprecated since macOS 10.15, and on Apple Silicon they require the user to downgrade boot security. | No kext, ever. Anything a kext could do that ES cannot is out of scope by platform decree. |
| L8 | Apple's "Allow accessory to connect" prompt exists only on Apple Silicon Mac laptops (macOS Ventura and later) and is not available to third parties, nor extensible by them. | It is the only pre-enumeration gate on the platform. Plugsight positions itself as the explanation layer behind that prompt, never as a substitute. Desktops (Mac mini, Studio, Pro) do not have the prompt at all, which makes detection there matter more. |
| L9 | VID, PID, serial, and all descriptor strings are attacker-controlled bytes. | Trust keyed on identity is a bar-raiser only. The charter requires the caveat wherever trust appears. |
| L10 | An attacker with root can unload or kill any monitoring, including ours. | Plugsight does not claim tamper-resistance. The daemon notes gaps in its own uptime in the timeline ("monitoring was off between X and Y") so at least the absence of data is legible. |

## What Plugsight explicitly cannot do

Restated once, for the record, because these are the claims marketing will be tempted to blur:

1. It cannot block a keystroke before it is typed (L2, L8).
2. It cannot see a dormant implant (T6).
3. It cannot scan a cable or a controller's firmware from the host. USB exposes descriptors and
   traffic, not flash contents.
4. It cannot survive a root-level attacker (L10).
5. It cannot make trust cryptographic. USB has no device identity worth the name (L9).

## Evasion, acknowledged

Behavioral scoring is a race we can lose. Slow typing beats the cadence signal; patient delays beat
the latency signal; a keyboard-only descriptor beats the mismatch signal; typing only when the user
is idle beats the redundancy heuristic in spirit. 05 quantifies what each signal still catches and
what it costs an attacker to evade (mostly: time, which is a real cost during physical-access
attacks). The product's stance: raising the attacker's cost and leaving a legible trail is worth
shipping, and pretending more than that is not.
