# ADR: Each container boots from a DiskImageKit overlay on an ASIF base

## Metadata

**Status:** Accepted
**Date:** 2026-10-18
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** storage, virtualization
**Supersedes:** N/A
**Superseded By:** N/A

## Context

A container boots its own instance of an installed macOS VM bundle, and the bundle must stay
unchanged. The first implementation cloned every file of the bundle with APFS `clonefile`, including
a raw `Disk.img` created with `truncate`.

macOS 27 adds DiskImageKit (WWDC26 session 224): raw and ASIF images, and layered stacks of a base,
read-only cache layers and copy-on-write overlays, attached through
`VZDiskImageStorageDeviceAttachment(diskImage:)`. Apple advises shallow stacks and states that the
auxiliary storage of a virtual Mac must be duplicated per clone, not shared.

Measured on this host, 2026-10-18, macOS 27.0.1:

- An overlay stacked on a raw base carries no parent UUID; DiskImageKit stacked it on an unrelated
  raw image without an error.
- An ASIF base has a layer UUID; an overlay created on it records it as parent UUID, and stacking it
  on another ASIF image fails with `IncompatibleStackingError` ("Parent UUID mismatch").
- `VZMacOSInstaller` installs macOS 27 onto an ASIF disk; a fresh overlay is 4 MB, one after two
  boots 3.8 GB.
- DiskImageKit offers `appending` and `truncate`, no flatten or merge.
- Two guests with the same `MachineIdentifier` ran at once with the same platform UUID and serial
  number. An installed bundle given a new `MachineIdentifier` booted, logged in automatically and
  reported a new UUID and serial number.

## Decision Drivers

- The base stays unchanged and is shared by every container.
- A container's writes must never stack on a base they were not made against.
- Hosts on macOS 15 to 26 keep working.
- Every running guest has its own identity (MDM, licences, Apple services key on it).

## Considered Options

### Option 1: APFS clone of the whole bundle

| Pros | Cons |
|------|------|
| Works on every macOS version | A raw image grows to full size when copied off APFS or distributed |
| No new framework | Base and clone must share an APFS volume |
| | No record of which base a clone belongs to |

### Option 2: Overlay on any base

| Pros | Cons |
|------|------|
| One code path for raw and ASIF | An overlay on a raw base binds to nothing and stacks on a wrong base silently |

### Option 3: ASIF base with an overlay per container, APFS clone for a raw base (chosen)

| Pros | Cons |
|------|------|
| DiskImageKit refuses a wrong base | Needs a macOS 27 host for the overlay path |
| ASIF stays sparse when copied or distributed | Two paths to maintain |
| Base may live on another volume | Booting the base read-write corrupts the overlays built on it |

## Decision Outcome

**Option 3.** `parbake install` creates an ASIF disk on a macOS 27 host (`--disk-format raw` keeps
the raw path). `MacOSVMBundle.instance(at:)` links an ASIF base read-only as `Disk.img` and creates
`Overlay.asif` bound to its layer UUID; a raw base is cloned with `clonefile`. The auxiliary storage,
hardware model, `Provisioned` and `GuestKey` are APFS clones; the `MachineIdentifier` is new for every
instance. DiskImageKit is weak-linked.

### Consequences

**Positive:**

- A container starts with a 4 MB overlay and keeps it across `container stop`/`start`; `container rm`
  discards it.
- A replaced base makes the attachment fail instead of booting a corrupt disk.
- Every instance has its own serial number and platform UUID.

**Negative:**

- A bundle must not be booted read-write while containers run from it (README).
- No API merges an overlay into its base; a new base layer is a new install or a conversion with
  `diskutil image create from`.

**Risks:**

- In-place writes to the base keep its layer UUID; the binding catches a replaced base, not a modified one.

## Validation

- [x] `InstanceTests`: an ASIF base gets an overlay bound to it; the overlay refuses another base;
      a raw base is cloned; the instance's machine identifier is new and valid.
- [x] On this host: containers booted from overlays, kept writes across restart, base timestamp
      unchanged.
- [ ] A cache layer for a base on a network volume.

## Links

- WWDC26 session 224: https://developer.apple.com/videos/play/wwdc2026/224/
- Code: `Sources/RuntimeMacOS/MacOSVMBundle.swift`

## Changelog

- 2026-10-18 — Initial version.
