<!-- doc_type: explanation -->
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
**Superseded By:** [ADR 0007](adr_0007_hosts_run_macos_27_and_disks_are_asif.md) for the raw disk path

## Context

A container boots its own instance of an installed macOS VM bundle, and the bundle must stay
unchanged. The first implementation cloned every file of the bundle with APFS `clonefile`, including
a raw `Disk.img` created with `truncate`.

macOS 27 adds DiskImageKit (WWDC26 session 224). It supports raw and ASIF images and layered stacks of a base,
read-only cache layers and copy-on-write overlays, attached through
`VZDiskImageStorageDeviceAttachment(diskImage:)`. Apple advises shallow stacks and states that the
auxiliary storage of a virtual Mac must be duplicated per clone, not shared.

Validation confirmed:

- An overlay stacked on a raw base carries no parent UUID. DiskImageKit stacked it on an unrelated
  raw image without an error.
- An ASIF base has a layer UUID. An overlay created on it records it as parent UUID, and stacking it
  on another ASIF image fails with `IncompatibleStackingError` ("Parent UUID mismatch").
- `VZMacOSInstaller` installs macOS 27 onto an ASIF disk. A fresh overlay starts small and grows
  with guest writes.
- DiskImageKit offers `appending` and `truncate`, no flatten or merge.
- Two guests with the same `MachineIdentifier` ran at once with the same platform UUID and serial
  number. An installed bundle given a new `MachineIdentifier` booted, logged in automatically and
  reported a new UUID and serial number.

Apple's sample "Running macOS in a virtual machine on Apple silicon", updated for macOS 27, ships a
`SharedBaseImageSampleApp` that does the same. It opens the base `.readOnly` and gives each virtual machine an
`.asifLayer(type: .overlay)`, a new `VZMacMachineIdentifier` and an own copy of the auxiliary
storage. When stacking fails with `IncompatibleStackingError`, it asks the user,
discards the overlays, copies the auxiliary storage again from the base bundle and starts over.

## Decision Drivers

- The base stays unchanged and is shared by every container.
- A container's writes must never stack on a base they were not made against.
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

### Option 3: ASIF base with an overlay per container (chosen)

| Pros | Cons |
|------|------|
| DiskImageKit refuses a wrong base | Needs a macOS 27 host |
| ASIF stays sparse when copied or distributed | Booting the base read-write corrupts the overlays built on it |
| Base may live on another volume | |

## Decision Outcome

**Option 3.** `parbake install` creates an ASIF disk. `MacOSVMBundle.instance(at:)` links the base read-only as
`Disk.img` and creates `Overlay.asif` bound to its layer UUID. The auxiliary storage,
hardware model, `Provisioned` and `GuestKey` are APFS clones, or copies when the bundle is on another
volume or not on APFS. The `MachineIdentifier` is new for every
instance. DiskImageKit is weak-linked.

An overlay that no longer stacks on its base surfaces as `IncompatibleOverlayError`. The label
`runtime-macos.on-incompatible-overlay` decides: `fail` (default) stops the start with an error that
names the label, because a container's writes must not vanish silently. `discard` removes the
overlay, links the bundle's disk image again, clones its auxiliary storage again and creates a new
overlay, as Apple's sample does. The instance keeps its machine identifier.

### Consequences

**Positive:**

- A container starts with a 4 MB overlay and keeps it across `container stop`/`start`. `container rm`
  discards it.
- A replaced base makes the attachment fail instead of booting a corrupt disk. A throwaway job can
  opt into starting over with `discard`.
- Every instance has its own serial number and platform UUID.

**Negative:**

- A bundle must not be booted read-write while containers run from it (README).
- No API merges an overlay into its base. A new base layer is a new install or a conversion with
  `diskutil image create from`.

**Risks:**

- In-place writes to the base keep its layer UUID. The binding catches a replaced base, not a modified one.

## Validation

- [x] `InstanceTests`: an ASIF base gets an overlay bound to it. The overlay refuses another base.
      The instance's machine identifier is new and valid.
- [x] Host integration validation: containers booted from overlays, kept writes across restart, base timestamp
      unchanged.
- [x] `ResetOverlayTests`: a reinstalled base reports `IncompatibleOverlayError`. The reset stacks
      again and keeps the machine identifier.
- [x] Host integration validation: with the base link pointed at another bundle, a container without the label
      fails with the label named in the error. One with `discard` starts over and boots.
- [x] `OtherVolumeTests`: an instance of an ASIF base on an HFS+ volume copies the auxiliary storage
      and stacks its overlay.
- [ ] A cache layer for a base on a network volume.

## Links

- WWDC26 session 224: https://developer.apple.com/videos/play/wwdc2026/224/
- Code: `Sources/RuntimeMacOS/MacOSVMBundle.swift`

## Changelog

- 2026-10-18: Initial version.
- 2026-10-18: Apple's shared-base sample as confirmation. The `runtime-macos.on-incompatible-overlay` label.
- 2026-10-20: The raw disk path is superseded by ADR 0007: hosts run macOS 27, every bundle disk is ASIF.
