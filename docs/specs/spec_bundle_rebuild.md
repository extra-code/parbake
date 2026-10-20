# Spec: Bundle rebuild — `parbake create` builds a fresh bundle every time

## Overview

**Status:** Implemented
**Author:** Christian Semmelmann
**Date:** 2026-10-20
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Decisions of record:** [ADR 0001](../adr/adr_0001_overlay_per_container_on_an_asif_base.md)
(overlays and a replaced base), [ADR 0007](../adr/adr_0007_hosts_run_macos_27_and_disks_are_asif.md)
(macOS 27 hosts, ASIF only).

A bundle creator rebuilds bundles from a fresh restore image instead of updating them in place.
`parbake create` therefore takes the restore image from Apple, a mirror or a local file. It replaces
an existing bundle only once the new one is complete, and it keeps one restore image in the cache.

## Goals

- **One option for the restore image source**, a path or a URL, with Apple's latest supported image
  as the default.
- **Rebuild without a gap:** an existing bundle stays usable until its replacement is provisioned.
- **A bounded cache:** after a successful build the cache holds the restore image just used.
- **One command for the whole job:** `create` covers what `ipsw-url` and the old script did.

## Non-goals

- Updating macOS inside an existing bundle with `softwareupdate`. A rebuild is the supported path.
- Verifying a restore image against a published checksum. Apple's API offers none, so C-001 checks
  that Virtualization.framework can load the image instead.
- Finding and stopping containers that use the bundle being replaced. C-002 warns, ADR 0001 governs
  what happens to their overlays.
- Distributing bundles to other hosts.

## User / Interaction Flow

1. **First build:** `parbake create --username runner --keychain` downloads Apple's latest
   supported restore image into the cache, installs it into `~/VM.bundle` and provisions it.
2. **Rebuild after a macOS update:** `parbake create --username runner --keychain --replace`
   builds next to the existing bundle, swaps it in after provisioning, and removes the previous
   restore image from the cache.
3. **Rebuild from a mirror:** `parbake create --restore-image https://mirror.example/<file>.ipsw --replace`
   takes the image from the mirror instead of Apple's CDN.
4. **Rebuild from a local file:** `parbake create --restore-image ~/Downloads/UniversalMac_….ipsw …`
   installs that file and leaves the cache alone.

## Component / Module Specifications

### C-001 — Restore image source: `--restore-image <path|url>`

- `parbake create --restore-image <value>` and `parbake install --restore-image <path>` replace
  `--ipsw`. `--ipsw` is removed without an alias.
- A value starting with `http://` or `https://` is a URL. Any other value is a local path.
- **URL:** `create` downloads it into the cache as `<cache>/<last path component>`. An interrupted
  download resumes on the next run. A finished download carries a `<file>.done` marker and is reused
  without a request.
- **Path:** `create` installs the file as it is. It neither copies it into the cache nor prunes the
  cache (C-003).
- **No value:** `create` asks `VZMacOSRestoreImage.latestSupported` for Apple's URL and continues as
  for a URL.
- Before writing `.done`, `create` loads the downloaded file with `VZMacOSRestoreImage.image(from:)`.
  A file that does not load is deleted, and the error says to run `create` again.
- `install` refuses a restore image the host cannot run and names the image's macOS version, as it
  does today.

### C-002 — Replace an existing bundle: `--replace`

- Without `--replace`, `create` refuses an existing bundle path and its error names `--replace`.
- With `--replace`, `create` builds into `<bundle>.parbake-new` next to the target. A leftover
  `<bundle>.parbake-new` from an interrupted run is removed first.
- Only after `install` and `provision` (or `setup`) succeed, `create` renames the target to
  `<bundle>.parbake-old`, renames the new bundle to the target path, and removes
  `<bundle>.parbake-old`.
- When any step fails, `create` removes `<bundle>.parbake-new` and leaves the target unchanged.
- Before it starts, `create --replace` prints that containers made from the bundle will not stack on
  the new base, and names the label `runtime-macos.on-incompatible-overlay` from ADR 0001.
- The new bundle needs as much free space as the existing one, beside it. `create` checks the free
  space on the target volume against the existing bundle's allocated size and refuses with both
  numbers when it is short. The disk image is sparse, so `--disk-size` overstates the need.

### C-003 — Cache pruning

- After a successful `create` that used a URL (C-001), `create` removes every other `*.ipsw`,
  `*.ipsw.done` and partial download in the cache directory.
- `--keep-cache` skips the pruning.
- Pruning touches only files with those suffixes directly in the cache directory. It never descends
  into subdirectories and never removes other files.
- A failed `create` prunes nothing, so a retry finds the previous image.

### C-004 — Command surface

- `parbake ipsw-url` is removed. `parbake create --help` names Apple's latest supported image as
  the default of `--restore-image`.
- `create` keeps `--cache-dir`, and `PARBAKE_HOME` keeps moving the default bundle and the cache.
- README, AGENTS.md and the plan name `--restore-image` and `--replace`.

## Interface Contract

### `parbake create` options (changed)

| Option | Meaning | Default |
|---|---|---|
| `--restore-image <path\|url>` | restore image to install, replaces `--ipsw` | Apple's latest supported image |
| `--replace` | replace an existing bundle once the new one is provisioned | off |
| `--keep-cache` | keep older restore images in the cache | off |

### `parbake install` options (changed)

| Option | Meaning | Default |
|---|---|---|
| `--restore-image <path>` | restore image to install, replaces `--ipsw` | required |

### Files next to the target bundle

| Path | Exists | Removed |
|---|---|---|
| `<bundle>.parbake-new` | while `create --replace` builds | on success after the swap, on failure, or by the next run |
| `<bundle>.parbake-old` | between the two renames of the swap | right after the swap |

## Non-Functional Requirements

- **No gap:** at every moment of `create --replace`, the target path holds either the previous
  bundle or the new, provisioned one.
- **Bounded disk use:** one restore image of about 27 GB in the cache after a successful build.
- **Same volume:** `<bundle>.parbake-new` is created next to the target, so the swap is a rename on
  one volume and never a copy.

## Traceability

| Goal | Components | Validation |
|---|---|---|
| One option for the source | C-001, C-004 | V-1, V-2, V-3 |
| Rebuild without a gap | C-002 | V-4, V-5 |
| A bounded cache | C-003 | V-6 |
| One command | C-004 | V-1 |

**Validation:**

- **V-1 — passed 2026-10-20:** `parbake ipsw-url` is unknown, `parbake create --help` lists `--restore-image`,
  `--replace` and `--keep-cache`, and `--ipsw` is rejected.
- **V-2 — passed 2026-10-20 (`RestoreImageSourceTests`, `RestoreImageCacheTests`):** unit test: a value with `http://` or `https://` is a URL, anything else a path. A cached
  image with `.done` is reused without a request.
- **V-3 — passed 2026-10-20 (`RestoreImageCacheTests`):** unit test: a downloaded file that `VZMacOSRestoreImage` cannot load is deleted and gets
  no `.done`.
- **V-4 — passed 2026-10-20 (`BundleReplacementTests`):** unit test with a stubbed build step: on failure the target is unchanged and
  `<bundle>.parbake-new` is gone. On success the target holds the new bundle and neither sibling
  remains.
- **V-5 — passed 2026-10-20:** on this host, `create --replace` on a provisioned bundle produces a bundle whose base
  has a new layer UUID. A container made from the old bundle then fails with the label named, as
  ADR 0001 specifies. Measured on an encrypted external APFS volume over USB with `PARBAKE_HOME` set:
  the first `create` downloaded the image and built and provisioned the bundle, about 6 minutes
  after the download. `create --replace` built `VM.bundle.parbake-new` from the cached image and
  swapped it in, and no sibling remained. The stopped container from the old bundle then failed
  to start with the label named in the error.
- **V-6 — passed 2026-10-20 (`RestoreImageCacheTests`):** unit test: with two images and a stray file in the cache, pruning leaves the used image,
  its `.done` and the stray file.

## Resolved Questions

Decided by Christian Semmelmann, 2026-10-20.

1. **Option name:** `--restore-image`, Apple's term in the API and the docs, instead of `--ipsw`.
2. **Rebuild over update:** a bundle creator always builds fresh, so `create` gets `--replace`
   rather than an update command.

## Open Questions

- None.

## Approval

- [ ] Decider: Christian Semmelmann
