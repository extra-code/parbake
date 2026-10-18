# ADR: The macOS guest agent speaks containerization's SandboxContext protocol over vsock

## Metadata

**Status:** Accepted
**Date:** 2026-10-18
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** guest-agent, protocol, upstream
**Supersedes:** N/A
**Superseded By:** N/A
**Amends:** [ADR 0003](adr_0003_controlled_shutdown_over_ssh.md) — once the agent runs, shutdown
goes through it and SSH becomes the fallback.

## Context

The runtime has no way to run a process in the guest other than SSH, no readiness signal, and stops
the guest over SSH (ADR 0003). SSH depends on the guest's address and sshd, and host-to-guest IP
traffic from the plugin is subject to Local Network privacy (ADR 0002).

containerization's Linux guest agent, vminitd, serves the gRPC service
`com.apple.containerization.sandbox.v3.SandboxContext` on vsock port 1024. The host dials it with
`VZVirtioSocketDevice.connect(toPort:)` and talks to it through `Vminitd`, which implements
`VirtualMachineAgent` and is public, as are the generated grpc-swift-2 service protocols
(`SandboxContext.ServiceProtocol`, `SimpleServiceProtocol`). A process's standard streams travel on
separate vsock ports that the host listens on and the guest connects to; their numbers are part of
`CreateProcessRequest`. The process is an OCI `Spec` encoded in `CreateProcessRequest.configuration`.

The macOS 27 SDK declares `AF_VSOCK` and `sockaddr_vm` (`sys/vsock.h`) with `VMADDR_CID_HOST`.

## Decision Drivers

- `container exec`, `container stop` and readiness for macOS guests behave like they do for Linux
  guests, through the same runtime XPC routes.
- vsock carries no IP traffic: no guest address, no Local Network approval.
- Reuse what containerization ships instead of a second protocol to maintain.
- The guest image changes only by what provisioning installs.

## Considered Options

### Option 1: Keep SSH

| Pros | Cons |
|------|------|
| Nothing to build | No stream separation, no exit status of signalled processes, no PTY resize |
| | Needs the guest's address and sshd; IP traffic from the plugin |

### Option 2: An own protocol over vsock

| Pros | Cons |
|------|------|
| Shaped for macOS only | A second wire format, client and server to write and version |

### Option 3: The SandboxContext protocol over vsock, the macOS subset (chosen)

| Pros | Cons |
|------|------|
| The host uses `Vminitd` unchanged | Linux-only RPCs return UNIMPLEMENTED |
| Stdio, wait, signals, resize, close-stdin as for Linux | Agent and host share containerization's protocol version |
| A `container` user sees the same behaviour for both guests | The agent links containerization and grpc-swift-2 |

## Decision Outcome

**Option 3.** The contract is
[spec_guest_agent.md](../specs/spec_guest_agent.md).

### Consequences

**Positive:**

- `container exec` and readiness without SSH; shutdown through the agent.

**Negative:**

- An agent installed in a bundle ties the bundle to a protocol version; the runtime must detect a
  mismatch and refuse or update the agent (spec, C-006).

**Risks:**

- An agent installed in many bundles has to keep up with containerization's `sandbox.v3` protocol.

## Validation

- [x] Spike V-1, 2026-10-18: an agent in a macOS 27 guest accepted a vsock connection on port 1024,
      and `Vminitd` on the host completed `Getenv`, `Sync` and an `UNIMPLEMENTED` call (spec, V-1).
- [x] `Vminitd` completed `WaitProcess` with exit 3 for a process started through the agent, with
      stdout and stderr delivered separately (spec, V-2), 2026-10-18.

## Links

- containerization `Sources/Containerization/SandboxContext/SandboxContext.proto`, `Vminitd.swift`,
  `VirtualMachineAgent.swift`
- [spec_guest_agent.md](../specs/spec_guest_agent.md)

## Changelog

- 2026-10-18 — Initial version.
- 2026-10-18 — Accepted.
