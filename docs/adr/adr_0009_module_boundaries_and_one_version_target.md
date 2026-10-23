<!-- doc_type: explanation -->
# ADR: Module boundaries: host targets use Virtualization directly, one leaf target owns version metadata

## Metadata

**Status:** Accepted
**Date:** 2026-10-22
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** architecture, guest-agent, versioning
**Supersedes:** N/A
**Superseded By:** N/A
**Amended By:** [ADR 0012](adr_0012_release_tag_is_the_version_source.md), release-version source only
**Classification:** cross-area, one-way door (medium). Every bundle's `Agent` file stores the
agent version line. Research: the codebase recon of 2026-10-22, nothing more.

## Context

The package's relevant SwiftPM targets are:

| Target | Kind | Runs | Links |
|--------|------|------|-------|
| `ParbakeVersion` | library | host and guest | none |
| `RuntimeMacOS` | library | host | `ParbakeVersion`, Virtualization, vmnet, Security, DiskImageKit, containerization |
| `container-runtime-macos` | executable, XPC service | host, user's launchd domain | `RuntimeMacOS`, `ParbakeVersion`, apple/container, Virtualization, vmnet |
| `parbake` | executable, CLI | host, user's terminal | `RuntimeMacOS`, `ParbakeVersion`, Virtualization, AppKit |
| `parbake-agent` | executable, daemon | guest | `ParbakeVersion`, containerization, grpc-swift-2 |

Two boundary decisions are recorded here. Release-version sourcing is refined in ADR 0012.

**(a) `parbake` imports Virtualization and AppKit.** The imports sit in four files:

- `Setup.swift` builds a `VZVirtualMachine` and shows it in an `NSWindow` with a
  `VZVirtualMachineView`, for the Setup Assistant.
- `Install.swift` and `Create.swift` call `VZMacOSRestoreImage` for the newest image and its
  hardware requirements.
- `StateProbe.swift` writes a fresh `VZMacMachineIdentifier`.

`RuntimeMacOS` is not a facade over Virtualization: its public API already carries
`VZMacHardwareModel`, `VZMacOSVirtualMachineStartOptions`, `VZDiskImageStorageDeviceAttachment`
and `VZVirtualMachineDelegate` methods. `container-runtime-macos` imports Virtualization and vmnet
too, for `VZMACAddress` and the vmnet network reference. `otool -L` of the debug build lists AppKit
for `parbake` only.

**(b) The agent version line needs a shared contract.** `ParbakeVersion` owns the protocol number
`1`, the environment-variable name `CONTAINER_RUNTIME_MACOS_AGENT` and the parser for the version
line. The guest agent reports `1 0.1.0`; the bundle's `Agent` file records that line. The release
value is currently a Swift constant, which ADR 0012 replaces with the version supplied by the
release tag. The wire shape remains `<protocol>` followed by optional informational fields (C-005).
The release workflow and generated notes are decided in
[ADR 0013](adr_0013_tagged_releases_and_git_cliff.md).

## Decision Drivers

- The XPC service links no framework it does not use, AppKit above all.
- The guest agent links no host code: nothing from `RuntimeMacOS`.
- The protocol number and agent-variable name each have one source, and the compiler sees every use.
- A release tag supplies the release version to the build; it is not independently bumped in source.
- The version line keeps the shape spec C-005 defines, so agents already in bundles stay valid.
- No refactor of VM paths runs ahead of their tests (release-audit decision: two stages).

## Considered Options

### (a) Where Virtualization and AppKit may be imported

#### Option A1: Host targets use Virtualization directly; AppKit stays in `parbake` (chosen)

| Pros | Cons |
|------|------|
| No code change and no risk to VM paths without tests | The boundary is a rule, not a compiler check |
| The setup window, the only UI, stays with the only interactive tool | Restore-image lookup sits in two `parbake` files |
| Matches `RuntimeMacOS`'s VZ-typed public API | |

#### Option A2: `RuntimeMacOS` becomes a facade; only it imports Virtualization

| Pros | Cons |
|------|------|
| One target knows the framework | Wraps six public signatures and the delegate in new types |
| | The setup window needs a UI target or AppKit in `RuntimeMacOS`, which the XPC service then links |
| | `container-runtime-macos` needs a wrapper for `VZMACAddress` and vmnet as well |

#### Option A3: Move the restore-image and identifier calls into `RuntimeMacOS`

| Pros | Cons |
|------|------|
| Three call sites fewer in `parbake` | `Setup.swift` still needs `VZVirtualMachine` and `VZVirtualMachineView`, so `parbake` keeps the import |
| | Churn without a boundary gained |

| Criterion (weight) | A1 | A2 | A3 |
|--------------------|----|----|----|
| XPC service links no AppKit (3) | 3 | 2 | 3 |
| Change risk before stage-2 tests (3) | 3 | 1 | 2 |
| Boundary a reader can state in one line (2) | 3 | 2 | 1 |
| Testability of VZ-free logic (2) | 2 | 3 | 2 |
| **Weighted total** | **28** | **19** | **21** |

### (b) Where the agent protocol version and the release live

#### Option B1: Stays as it is

| Pros | Cons |
|------|------|
| No change | The release value is manually maintained in source and can drift from the tag |
| The agent already reports a release in the version line | A release requires editing the source constant |

#### Option B2: One leaf target `ParbakeVersion` for protocol metadata and the stamped release (chosen)

| Pros | Cons |
|------|------|
| One edit changes protocol metadata; the release tag supplies the release value | Every executable depends on the leaf target |
| The agent can report `<protocol> <release>`, so the bundle records the release | Release builds need a separate stamped source tree |
| No dependency, so the agent links no host code | |
| The line keeps its C-005 shape; old agents that send `1` stay accepted | |

#### Option B3: The agent depends on `RuntimeMacOS` for the constants

| Pros | Cons |
|------|------|
| No new target | The guest binary links bundle cloning, DHCP, keychain and VM code it never runs |

#### Option B4: A typed version through a new RPC or a proto field

| Pros | Cons |
|------|------|
| A structured value on the wire | A new RPC or field changes containerization's `sandbox.v3` messages, which ADR 0006 uses unchanged |
| | Installed agents lack the RPC, so readiness needs a fallback to `Getenv` anyway |

#### Option B5: The host appends its release to the `Agent` file at install time

| Pros | Cons |
|------|------|
| The agent needs no release stamp in its binary | The bundle records the installing runtime's version, not the live agent's |
| | The live agent version line has no release for readiness checks |

| Criterion (weight) | B1 | B2 | B3 | B4 | B5 |
|--------------------|----|----|----|----|----|
| No duplicated protocol or release value (3) | 1 | 3 | 2 | 2 | 1 |
| Agent links no host code (3) | 3 | 3 | 1 | 3 | 3 |
| Installed agents stay valid (3) | 3 | 3 | 3 | 1 | 3 |
| Change size (1) | 3 | 2 | 2 | 1 | 3 |
| **Weighted total** | **24** | **29** | **20** | **19** | **24** |

The protocol metadata is a Swift constant in that target. The release value is supplied explicitly
from the release tag and stamped into a temporary build worktree as specified in ADR 0012. Runtime
code does not inspect Git, and the tag is never inferred with `git describe`.

## Decision Outcome

**(a) Option A1, stays as it is, with the boundary written down.**

| Target | May import | Never imports |
|--------|-----------|---------------|
| `ParbakeVersion` | nothing | anything |
| `RuntimeMacOS` | Virtualization, vmnet, Security, DiskImageKit, containerization, `ParbakeVersion` | AppKit |
| `container-runtime-macos` | `RuntimeMacOS`, apple/container, Virtualization, vmnet, `ParbakeVersion` | AppKit |
| `parbake` | `RuntimeMacOS`, Virtualization, `ParbakeVersion`; AppKit only in `Setup.swift` | — |
| `parbake-agent` | containerization, grpc-swift-2, swift-nio, `ParbakeVersion` | `RuntimeMacOS`, Virtualization, AppKit |

The agent links Virtualization.framework only transitively through containerization, which
`otool -L` shows. That is accepted: the framework ships with every macOS guest.

**(b) Option B2.** `ParbakeVersion` has no dependencies and owns protocol metadata and the agent
version-line contract. The release value embedded in that target comes from the release tag for
release builds; ordinary builds use the committed development sentinel. The two CLIs, the runtime
and the agent read that compiled value. `RuntimeMacOS` imports it with a plain `import ParbakeVersion`. The tag-to-artifact contract is specified in ADR 0012.

### Component contracts

```swift
// Sources/ParbakeVersion/ParbakeVersion.swift
public enum Parbake {
    /// The release embedded by the build; untagged builds report the development sentinel.
    public static let release = "0.0.0-dev" // STAMP:release
}

/// The agent's version line: `<protocol>` followed by optional informational fields (spec C-005).
public struct AgentVersionLine: Equatable, Sendable, CustomStringConvertible {
    /// The wire protocol; it changes only when spec_guest_agent changes the wire contract.
    public static let protocolVersion = 1
    /// The agent environment variable whose value is the version line.
    public static let variable = "CONTAINER_RUNTIME_MACOS_AGENT"
    /// The line this build's agent sends: `"\(protocolVersion) \(Parbake.release)"`.
    public static let current: AgentVersionLine

    public let protocolNumber: Int
    /// The second field, or nil when the line has none or it is not a valid release.
    public let release: String?

    public init(protocolNumber: Int, release: String?)
    /// Parses a line; nil when the first field is not a decimal integer.
    public init?(_ line: String)
    /// `"<protocol> <release>"`, or `"<protocol>"` without a release.
    public var description: String { get }
}
```

Parsing rules for `init?(_:)`, which reads text from the guest:

- Leading and trailing whitespace and newlines are trimmed. The line is split on each single space,
  so `"1  0.1.0"` has an empty second field and yields release nil.
- The first field must be one or more ASCII digits, else the result is nil. `"+1"` is nil.
- The second field becomes `release` only when it is 1 to 32 characters drawn from `0-9`, `A-Z`, `a-z`, `.`, `-` and `+`.
  Otherwise `release` is nil. Further fields are ignored.
- Examples: `"1"` → (1, nil); `"1 0.1.0\n"` → (1, "0.1.0"); `"1 0.52.0 x"` → (1, "0.52.0");
  `"x 0.1.0"` → nil; `""` → nil.

Uses:

- `parbake-agent` sets `AgentVersionLine.variable` to `AgentVersionLine.current.description`. It
  drops its own `protocolVersion` and `versionVariable`.
- `GuestAgent` drops `protocolVersion`, `versionVariable` and `protocolNumber(of:)`.
  `waitUntilReady` accepts a line whose `AgentVersionLine(_:)?.protocolNumber` equals
  `AgentVersionLine.protocolVersion`. Any other line throws `VersionMismatch`, as now, and its
  message reads `AgentVersionLine.protocolVersion`. `waitUntilReady` still returns the raw line, so
  `AgentSetup` writes the `Agent` file unchanged.
- `MacOSVMBundle` gains `agentVersionLine: AgentVersionLine?`, parsed from `agentVersion`.
- `ParbakeTool` and `RuntimeMacOSHelper` set `version: Parbake.release`. `AgentProbe` reads
  `AgentVersionLine.variable`.
- `RuntimeService` logs a warning once the agent is ready, when the release of the live line from
  `waitUntilReady` differs from `Parbake.release`. That includes a nil release. The warning names
  the live line, the bundle's recorded line and `parbake agent install`. The live line decides,
  because an agent can change in the guest after the `Agent` file was written. A release mismatch
  never fails the start. A protocol mismatch still fails readiness.
- Unchanged: the `agentVersion != nil` checks in `RuntimeService`, `Layer` and `StateProbe`.

### Structure

- **Context:** `container` CLI → XPC → `container-runtime-macos` → Virtualization.framework → macOS
  guest → `parbake-agent`. The operator runs `parbake` to build bundles.
- **Containers:** the three executables in the table above. The host and the guest share only the
  version line on vsock and in the bundle's `Agent` file.
- **Components:** `ParbakeVersion` is the leaf every executable depends on. `RuntimeMacOS` is the
  host library under both host executables. The agent shares nothing else with the host.

### Rationale

(a) `parbake` keeps the Virtualization import under any option, because the setup window needs
`VZVirtualMachineView`. A facade would wrap a VZ-typed API for no consumer that lacks the framework.
The one boundary that matters, no AppKit in the XPC service, holds today and is now written down.

(b) The protocol number is a contract between two binaries built from one checkout (spec_guest_agent,
decision 4). A shared constant turns a drift between them into one edit. The release in the second
field uses room the spec already reserves. Both directions stay compatible. A new runtime accepts an
installed agent's `1`, and an old runtime splits `1 0.1.0` on the space and reads `1`.

### Consequences

**Positive:**

- One release tag supplies the version reported by `parbake --version`,
  `container-runtime-macos --version` and the agent's version line.
- The plugin can name a stale agent in a bundle before a job notices.

**Negative:**

- Bundles provisioned before this change record `1` and log the release warning on every start
  until `parbake agent install` runs.
- Release builds need a temporary source worktree and a separate verification step. Ordinary local
  builds continue to use the development sentinel.
- Two development builds have the same sentinel; it identifies a development build, not a commit.

**Neutral:**

- The wire shape and the protocol number stay unchanged; the `Getenv` value gains a second field.
  It replaces the spec's example field, containerization's version, with the Parbake release.

### NFR coverage

- **Security:** the version line comes from the guest. Only the first field is interpreted; the
  release is bounded to 32 characters of a fixed set and is only compared and logged.
- **Operability:** a stale agent shows up as a warning in the runtime's log.
- **Cost:** release CI validates and stamps one tag value; no release version is maintained in a
  second tracked location.

## Implementation

- [ ] `Package.swift`: target `ParbakeVersion` with no dependencies. `RuntimeMacOS`,
  `container-runtime-macos`, `parbake` and `parbake-agent` depend on it. A new test target
  `ParbakeVersionTests` covers it. `Taskfile.yml` signing is unchanged, since the target is a library.
- [ ] `Sources/ParbakeVersion/ParbakeVersion.swift`: `Parbake` and `AgentVersionLine`, with the
  development sentinel and release-stamping marker, per the contracts above.
- [ ] `Sources/parbake-agent/main.swift`: sets the variable from `AgentVersionLine.current`; local
  constants removed.
- [ ] `Sources/RuntimeMacOS/GuestAgent.swift`: uses `AgentVersionLine`, also in
  `VersionMismatch.description`; `protocolVersion`, `versionVariable` and `protocolNumber(of:)`
  removed. `RuntimeMacOS` imports `ParbakeVersion` with a plain `import`.
- [ ] `Sources/RuntimeMacOS/MacOSVMBundle.swift`: `agentVersionLine`.
- [ ] `Sources/parbake/ParbakeTool.swift`, `Sources/container-runtime-macos/RuntimeMacOSHelper.swift`:
  `version: Parbake.release`.
- [ ] `Sources/parbake/AgentProbe.swift`: `AgentVersionLine.variable`.
- [ ] `Sources/container-runtime-macos/RuntimeService.swift`: the release warning after readiness.
- [ ] `Tests/RuntimeMacOSTests/GuestAgentTests.swift`: the `protocolNumber(of:)` cases move to
  `Tests/ParbakeVersionTests/` as `AgentVersionLine` parsing tests.
- [ ] `scripts/lint-boundaries.sh`, run by `task lint`: a check that fails on `import AppKit` in any Swift file other than
  `Sources/parbake/Setup.swift`, and on `import RuntimeMacOS` or `import Virtualization` under
  `Sources/parbake-agent/`.
- [ ] `docs/specs/spec_guest_agent.md`: C-005 and the bundle-file table name the second field as
  the Parbake release, example `1 0.1.0`.
- [ ] `AGENTS.md` › "Architecture rules": the import table of (a), as one rule.

## Validation

- [ ] Parsing tests cover the examples above, `"+1"`, `"1  0.1.0"` and a 33-character release.
- [ ] Untagged `parbake --version` and `container-runtime-macos --version` print the development
  sentinel; a tagged release prints the tag version in both CLIs.
- [ ] After `parbake agent install`, the bundle's `Agent` file reads the protocol number and the
  same release version embedded in the tagged build.
- [ ] A bundle whose `Agent` file reads `1` starts and logs the release warning.
- [ ] The import lint fails on a planted `import AppKit` in `Sources/RuntimeMacOS/` and passes
  on the tree.
- [ ] `otool -L` of `container-runtime-macos` lists no AppKit.

## Links

- [spec_guest_agent.md](../specs/spec_guest_agent.md), C-005 and C-006
- [ADR 0006](adr_0006_guest_agent_speaks_the_sandbox_context_protocol.md)
- [ADR 0012](adr_0012_release_tag_is_the_version_source.md), release-version source and stamping
- [ADR 0013](adr_0013_tagged_releases_and_git_cliff.md), tag workflow and release notes

## Changelog

- 2026-10-22 — Initial version.
- 2026-10-22 — Release versions come from the tag and are stamped by the release build, per ADR 0012.
