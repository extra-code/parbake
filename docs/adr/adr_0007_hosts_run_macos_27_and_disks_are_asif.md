# ADR: Hosts run macOS 27 or later, and every bundle disk is ASIF

## Metadata

**Status:** Accepted
**Date:** 2026-10-20
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** storage, virtualization, platform
**Supersedes:** the raw disk path of [ADR 0001](adr_0001_overlay_per_container_on_an_asif_base.md)
**Superseded By:** N/A

## Context

[ADR 0001](adr_0001_overlay_per_container_on_an_asif_base.md) gives every container a DiskImageKit
overlay on an ASIF base. It keeps a second path for hosts on macOS 15 to 26: a raw `Disk.img`
cloned per container with APFS `clonefile`. DiskImageKit exists from macOS 27 on, so only the raw
path runs on older hosts.

The raw path costs more than it returns:

- An overlay stacks only on an ASIF base. A raw clone records no base, so a container's writes can
  end up on a wrong base unnoticed.
- A raw image takes its full size when it leaves APFS. Its bundle must share an APFS volume with
  the containers, while an ASIF bundle may live on an external disk.
- Two code paths in `MacOSVMBundle`, `parbake install --disk-format`, weak linking of DiskImageKit,
  `#available` checks and tests for both.

The plugin is a proof of concept with no established external user base, so no installed base
depends on older hosts.

## Decision Drivers

- One disk path, the one that refuses a wrong base.
- Bundles may live on any volume.
- Less code to test and maintain.

## Considered Options

### Option 1: Keep both paths

| Pros | Cons |
|------|------|
| Hosts on macOS 15 to 26 work | Two paths; the raw one stacks silently on a wrong base |

### Option 2: macOS 27 hosts and ASIF only (chosen)

| Pros | Cons |
|------|------|
| One path, every container bound to its base | Hosts on macOS 26 or older are not supported |
| DiskImageKit linked normally, no `#available` | A raw bundle from an older install must be rebuilt |

## Decision Outcome

**Option 2.** The plugin and parbake require a macOS 27 host. `parbake install` creates an ASIF
disk only. The plugin refuses a bundle whose `Disk.img` is raw, and its error names
`parbake create`.

The guest version is a separate limit. The host's Virtualization.framework caps
it at the host's own version (see [architecture.md](../architecture.md), "Host and guest
versions").

### Consequences

**Positive:**

- Every container's writes are bound to the base they were made against.
- `MacOSVMBundle.instance(at:)` has one path: link the base, create the overlay.

**Negative:**

- Hosts on macOS 26 or older cannot run macOS containers.
- The package's platform applies to every target, so `parbake-agent` needs a macOS 27 guest. A
  bundle from `parbake create` has the host's version, and provisioning already needs a macOS 27
  guest. A bundle with an older guest runs without the agent, with SSH for shutdown.

### Implementation

- [x] `Package.swift`: platform macOS 27, DiskImageKit linked normally.
- [x] `MacOSVMBundle`: remove the raw branch of `instance(at:)`, `clone(to:)` and the
      `#available(macOS 27, *)` checks. Refuse a raw base with a message naming `parbake create`.
- [x] `parbake install`: remove `--disk-format`.
- [x] Tests: remove the raw cases, add one for the refused raw base.
- [x] README: requirements name a macOS 27 host.

## Validation

- [x] `task test` green after the raw path is gone (42 tests, 2026-10-20).
- [x] A raw bundle is refused with the message naming `parbake create` (`InstanceTests`).

## Links

- [ADR 0001](adr_0001_overlay_per_container_on_an_asif_base.md)
- [architecture.md](../architecture.md), "Disks: what DiskImageKit governs"

## Changelog

- 2026-10-20 — Initial version.
