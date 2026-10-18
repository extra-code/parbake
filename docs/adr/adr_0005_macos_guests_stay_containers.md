# ADR: macOS guests stay containers, not `container machine` machines

## Metadata

**Status:** Accepted
**Date:** 2026-10-18
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** product, upstream
**Supersedes:** N/A
**Superseded By:** N/A

## Context

`container machine ls` lists the machines of `MachineAPIService`, a separate service with its own
`MachineBundle` registry. A machine boots a Linux container with a kernel and an ext4 root file
system from the machine image, created with `autoRemove: true`; its persistent state lives in the
machine bundle. The service has no runtime selection and no `[runtimeConfig]`. apple/container
#2322 removed machine extension points.

A macOS guest is a container created with `--runtime container-runtime-macos`. It already keeps its
overlay across `container stop` and `start`, and `container ls` shows its address (ADR 0002).

## Decision Drivers

- The upstream contribution stays small and runtime-neutral.
- A persistent macOS guest is possible without the machine service.

## Considered Options

### Option 1: Make `container machine` runtime-selectable

| Pros | Cons |
|------|------|
| `machine ssh`, default machine, init scripts for macOS | A larger upstream change in a service Apple keeps Linux-specific |
| | The overlay would have to move from the container root to the machine bundle |

### Option 2: macOS guests stay containers; machine-style conveniences on this side (chosen)

| Pros | Cons |
|------|------|
| No upstream change beyond the runtime hooks | `container machine` users see no macOS guests |
| Works today | Conveniences such as SSH by name are built here |

## Decision Outcome

**Option 2.** Conveniences that `machine` offers for Linux, such as
an SSH entry by name, go into `parbake`.

### Consequences

**Positive:**

- The upstream proposal stays the `[runtimeConfig]` hooks and the exit-handler fix.

**Negative:**

- Two listings for two kinds of guests: `container machine ls` and `container ls`.

## Validation

- [x] Accepted by the decider, 2026-10-18.

## Links

- apple/container `Sources/Services/MachineAPIService/Server/MachinesService.swift`
- apple/container #2322

## Changelog

- 2026-10-18 — Initial version.
- 2026-10-18 — Accepted.
