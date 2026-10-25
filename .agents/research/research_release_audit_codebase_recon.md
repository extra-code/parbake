# Research: Parbake codebase recon for the release audit

## Metadata

**Date:** 2026-10-22
**Domain:** testing
**Triggered by:** `.agents/discussions/release-audit.md` — entry recon lane
**Expires:** 2026-11-22 (the code moves fast; re-run before the review)

Read-only recon of `main` at `3607458`. `task check` was not run, so the test status is read from source.

## Direct Answer

- About 3.8k lines of Swift in `Sources/` and 1.0k in `Tests/`, across four products (`Package.swift:7-10`):
  - the plugin `container-runtime-macos`;
  - `parbake`;
  - `parbake-agent`;
  - the library `RuntimeMacOS`.
- `spec_bundle_rebuild` and `spec_layer_bundles` are Implemented and their V-n steps passed. All eight ADRs are Accepted.
- `spec_guest_agent.md` still says `Status: Draft` (line 5):
  - V-4 is half passed; the simulator half needs a bundle with Xcode.
  - `provision` with the agent ran only as unit tests.
  - C-007, file copy, is reserved and not implemented.
- Other open items:
  - ADR 0001 has an unchecked cache layer for a base on a network volume (`adr_0001:127`).
  - All three specs have unchecked Approval boxes.
- Release mechanics:
  - There are no tags, no CHANGELOG, no release workflow and no SECURITY.md.
  - `0.1.0` is hardcoded in `ParbakeTool.swift:8` and in `RuntimeMacOSHelper.swift:8`.
- The build needs the extra-code/container fork: apple/container `804209b1` plus three runtime-plugin commits, pinned by revision.
- Not covered by automated tests: guest boot, DHCP, the vsock agent, XPC and `RuntimeService`.

## Key Findings

### Features

- **XPC routes** (`RuntimeMacOSHelper+Start.swift:51-74`):
  - Implemented: createEndpoint, bootstrap, createProcess, state, stop, kill, resize, wait, start and shutdown.
  - `unsupported` (`RuntimeService.swift:361`): dial, statistics, copyIn, copyOut, snapshotDisk and clean. The README lists them as limitations.
- **Labels:** `runtime-macos.bundle`, `.on-incompatible-overlay` and `.readiness-timeout` (`RuntimeService.swift:93-109`). The README documents them.
- **parbake commands:** create, install, provision, setup, agent install, layer, agent-probe and state-probe.
  - `create --config` (`BundleConfiguration.swift`) has no spec. Only the README and `BundleConfigurationTests` describe it.
- **Guest agent:** C-001 to C-006 are implemented. ADR 0006 is Accepted while the spec is still Draft.
- **ADR 0008:** all boxes are checked.
- **Deviations the README records:**
  - Signals sent to `exec` fail upstream (apple/container#1941).
  - `run -it` shows no guest output.

### Tests

There are about 75 `@Test` functions (Swift Testing).

**Covered, needs the host:**
- `MacOSVMBundle`, via DiskImageKit. `OtherVolumeTests` is serialized and uses an HFS+ volume.
- `GuestCredentials`, which calls the real `/usr/bin/security` (`GuestProvisioningTests.swift:122`).

**Covered, pure unit tests:**
- `RestoreImages`, `GuestPreparation`, `GuestUser`, `GuestAgentInstallation`, `DHCPMessage`, `DHCPLeases`, `ParbakeHome` and `BundleConfiguration`.
- `GuestAgent` has only eight small tests.

**No tests, and no test target exists:**
- all of `Sources/container-runtime-macos/` (`RuntimeService` has 533 lines);
- all of `Sources/parbake-agent/` (`GuestProcess` has 507 lines).

**No tests, inside existing modules:**
- `MacOSVirtualMachine.swift` (497 lines), `GuestDHCPServer.swift` and `GuestShell.swift`;
- the parbake commands Create, Provision, Setup, Layer, Agent, Install, AgentProbe, StateProbe, GuestScript and AgentSetup.

**What CI runs:** `task check` (lint, build, ad-hoc signing, `swift test`), and nothing else (`ci.yml:52`). Guest boot and the V-n steps are manual only.

### Duplication

- Draining a pipe through a Thread plus a `usleep` spin is copied: `GuestShell.swift:98-105` and `GuestCredentials.swift:117-124`.
- `Process()` is set up in five places without a shared helper: `GuestShell:80`, `GuestCredentials:103`, `RestoreImages:94`, `Provision:145` and `GuestProcess:438`.
- `sudo -n /sbin/shutdown -h now` over SSH appears five times: `Provision.swift:119`, `Agent.swift:71`, `AgentProbe.swift:84`, `RuntimeService.swift:507` and `GuestPreparation.swift:37`.
- The `sudo -S … /bin/sh -c "$PARBAKE_ROOT"` wrapper appears in `GuestPreparation.swift:56` and `GuestAgentInstallation.swift:65`.
- `/bin/bash -s` over SSH appears in `Provision.swift:108` and `Agent.swift:63`.
- Error types are ad hoc:
  - `IncompatibleOverlayError`, `VersionMismatch`, `ProcessLost` and `AgentError`;
  - mixed with `ContainerizationError` and `ValidationError`.
- Wait-for-guest loops (DHCP lease plus SSH with a deadline) are probably repeated across the Provision, Agent, Setup and Layer commands. This was not diffed.

### Architecture

- **Module dependencies:**
  - `RuntimeMacOS` → Containerization, ContainerizationOCI, GRPCCore, NIOPosix.
  - The plugin → `RuntimeMacOS` plus the apple/container products.
  - `parbake` → `RuntimeMacOS`, Containerization, NIOPosix, TOMLDecoder. It also imports AppKit and Virtualization directly.
  - `parbake-agent` stands alone and shares no protocol-version code with the host.
- No layering violation from the plugin towards the library was found.
- Because `Package.swift` depends on the fork by revision, the package needs the fork's `container` build at run time, not a stock release.

### Security surfaces

- **Signing:** the only entitlement is `com.apple.security.virtualization`. Signing is ad hoc, with no Developer ID, notarization or hardened runtime. `parbake-agent` is signed without entitlements.
- **SSH host keys:** `StrictHostKeyChecking=no` and `UserKnownHostsFile=/dev/null` (`GuestShell.swift:37-38`).
- **Password handling:**
  - The password reaches SSH through an askpass script (mode 0700, temp dir) and the env var `PARBAKE_SSH_PASSWORD`.
  - It also reaches `sudo -S` on stdin.
  - Script text interpolates the user name, keys and commands. Some of it is validated by tests.
- **Keychain:** items are created through `security -i` with `-A`, so any application can read them (ADR 0004).
- **Agent:** it refuses vsock connections from inside the guest, and its socket is root-only. Both were verified manually.
- **XPC input:** the bundle path comes from the `runtime-macos.bundle` label, with no allow-list.
- **Downloads:** a `--restore-image` URL is fetched with `curl --fail --location`, with no checksum because Apple publishes none. The image is validated only by loading it.
- **Force unwraps:** `GuestProcess.swift:223` and `:506`, `DHCPLeases.swift:30`.

### Docs drift

- `spec_guest_agent` is still Draft although the feature has shipped.
- `create --config` has no spec.
- `.agents/plans/plan_macos_runtime.md` still lists open decisions: image distribution, org name, an upstream PR to apple/container, and the signing identity.

### Code markers

There are no TODO, FIXME, XXX, `fatalError`, `try!`, `as!` or `precondition` occurrences.

## negative

- No integration test boots a guest in CI.
- No SBOM or checksums are produced.
- No known_hosts handling exists; it is disabled.

## leads

- **upstream-dependency:** check the status of an apple/container PR for the runtime-plugin hooks.
- **test-gap-agent-plugin:** find the seams in the agent and `RuntimeService` that can be tested without a VM.
- **ssh-hardening:** host-key pinning and the password path.
- **xcode-simulator-validation:** spec_guest_agent V-4.
