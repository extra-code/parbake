# Research: Council — which criteria block Parbake's first release

## Metadata

**Date:** 2026-10-22
**Domain:** security
**Triggered by:** `.agents/discussions/release-audit.md` — council lane
**Expires:** 2027-01-22

Three researcher seats answered independently, each from one perspective: premortem, operability and simplicity. No seat saw the others' answers or the user's preference.

## Agreements (all three seats)

- **Blocker:** a recorded manual end-to-end run on the exact release commit. It creates a bundle, boots, provisions over SSH, runs `exec`, stops and checks that no overlays leak. The release notes record the date, the host macOS version and the commit. CI cannot boot a VZ guest, so this run is the gate.
- **Blocker:** an explicit boundary between supported and experimental features in the README. The guest agent is labelled experimental, or Draft. The agent spec does not have to be finished first: V-4 and C-007 stay open.
- **Blocker:** honest dependency docs. They name apple/container `804209b1` plus the fork's commits and the supported host versions.
- **Blocker:** the known security limits are written down:
  - SSH host-key checking is off (`Sources/RuntimeMacOS/GuestShell.swift:37`);
  - keychain items are created with `-A` (`Sources/RuntimeMacOS/GuestCredentials.swift:45`);
  - no allow-list for the XPC bundle path;
  - no checksum for restore images;
  - signing is ad hoc only.
- **Blocker:** a tag plus release notes.
- **Defer:** test targets for the plugin and the agent. All three seats call this the 0.2 goal and say the manual end-to-end run covers it for 0.1.
- **Defer:** refactors to remove duplication. Their reason: refactoring without tests on the VM paths adds risk right before a release.
- **Defer:** notarization and Developer ID signing, a self-hosted VZ runner, and pinning SSH host keys.

## Divergences

| Point | Premortem | Operability | Simplicity |
|---|---|---|---|
| Security code fixes | Blocker: drop `-A` for a scoped ACL, and validate the XPC bundle path | XPC allow-list only if cheap, the rest documented | All documented, none fixed |
| Release artifact | Reproducible build from a clean clone, scripted; checksum for a binary | Release workflow that produces a tarball plus SHA-256 | Source tag only, no workflow |
| Version | One single source | Blocker: one source, shown at startup, warning when plugin and agent versions differ | Not a blocker |
| Observability | — | Blocker: errors name the stage that failed; an `os_log` subsystem (there are 0 `Logger` calls today) | — |
| Cleanup | Verify cleanup after a failure | Document how to remove stale overlays, since `clean` is unsupported | — |
| SECURITY.md | Blocker, with a threat model | Blocker, one page | Optional |

## Synthesis

The seats agree on the gate for a first release: a recorded end-to-end run, honest docs about limits and dependencies, and a tag. They disagree on how far security and operability have to be fixed in code before that.

Seen as a request for a quality audit, all three seats put test depth and duplication after the release, and they agree on the order: build the test seams first, refactor after that.
