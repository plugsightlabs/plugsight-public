# ESExtension — bundle templates and the manual dev-machine gate (N12)

This directory holds the NON-SOURCE templates for the real system-extension
bundle (`com.plugsight.esext`). The code lives in SPM targets:

- `Sources/PlugsightESCore/` — the PURE decision layer (mount-hold decision,
  deadline budget, XPC peer validation, policy cache). CI-tested:
  `swift test --filter PlugsightESCoreTests`.
- `Sources/PlugsightESExtension/` — the THIN ES/XPC plumbing. Compiles in CI;
  cannot run there (root + the restricted ES entitlement, docs/spec/07).

| File | Purpose |
| --- | --- |
| `Info.plist` | Bundle identity + `NSEndpointSecurityMachServiceName` (must match `ESDefaults.machServiceName`). |
| `plugsight-esext.entitlements` | `com.apple.developer.endpoint-security.client` — signable for distribution only after N0's Apple grant (RELEASE gate, not a merge gate). |

The bundle itself is assembled by the app's Xcode project at packaging time
(N13) at `Plugsight.app/Contents/Library/SystemExtensions/`, activated via
`OSSystemExtensionRequest` from the app (N11 drives the approval UX).

## The manual dev-machine session (NAMED MANUAL GATE, 07)

Runs on the dedicated SIP-relaxed test machine only. Never relax SIP on a
daily-driver.

One-time machine prep:

1. Boot into recovery, `csrutil disable` (or at minimum
   `csrutil enable --without sysext` per current macOS guidance).
2. `systemextensionsctl developer on`
3. In `Signing & Capabilities`, sign the extension to run locally
   (get-task-allow / dev certificate); the restricted ES entitlement is
   honored in this mode without the distribution grant.

Session script (record terminal output + screenshots as the gate evidence):

1. **Activation flow.** Build the app with the extension bundled, launch it,
   trigger activation. EXPECT: the System Settings approval prompt; after
   approval `systemextensionsctl list` shows `com.plugsight.esext` as
   `[activated enabled]`.
2. **Events arriving.** Start the daemon, connect to the extension's XPC
   service. Insert any USB stick. EXPECT: `mount`/`unmount`/`iokitOpen`
   events logged by the daemon; `log stream --predicate 'subsystem ==
   "com.plugsight.esext"'` shows the extension's own AUTH_MOUNT decision
   lines with reasons.
3. **Held mount releasing after a clean scan.** Enable policy
   `holdUntilScanned` (owner-gated `policy.set` with `confirm:true`), insert
   an UNTRUSTED stick. EXPECT: volume does not mount (Finder shows nothing);
   extension log shows `AUTH_MOUNT diskN -> DENY (untrustedHold)`; the daemon
   scans via private remount and, on a clean result, remounts — the volume
   appears in Finder without reinsertion.
4. **Fail-open probes.** (a) `kill -9` the daemon, wait past the policy TTL
   (60 s), insert the untrusted stick again. EXPECT: mounts normally, log
   line `ALLOW (cacheStale)`. (b) Fresh boot with the daemon never started:
   EXPECT `ALLOW (cacheAbsent)`.
5. Attach the recorded output to the PR; the orchestrator tracks this gate as
   pending owner evidence until then.
