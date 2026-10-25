# Spec: Layer bundles, a read-only layer between the base and a container's overlay

## Overview

**Status:** Implemented
**Author:** Christian Semmelmann
**Date:** 2026-10-21
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Decisions of record:** [ADR 0001](../adr/adr_0001_overlay_per_container_on_an_asif_base.md)
(overlay per container), [ADR 0007](../adr/adr_0007_hosts_run_macos_27_and_disks_are_asif.md)
(ASIF only).

A CI job needs more than macOS: Xcode, simulators, toolchains. Installing them per job takes far
longer than the job. Installing them into the base makes every base rebuild repeat the install.
A layer bundle keeps them in a layer of their own. The base stays as `parbake create` built it,
the layer holds what a script installed on it, and every container writes to its own overlay on
top. The stack is base, layer and overlay, three levels.

## Goals

- **Install once, use per container:** a container from a layer bundle starts with the layer's
  content and writes nothing into it.
- **The base stays unchanged:** building a layer reads the base and writes only the layer.
- **The same binding as overlays:** a layer records its base's layer UUID, and an overlay records
  the layer's. A rebuilt base or layer makes the stacks above it fail to open.
- **One command:** `parbake layer` creates the bundle, runs the script and shuts the guest down.

## Non-goals

- Downloading Xcode. Apple serves it only to a signed-in account, so the script gets it from a
  place the operator provides.
- A layer on a layer. Apple advises against deep stacks, and three levels cover base, toolchain
  and job.
- Merging a layer into its base, which DiskImageKit has no API for.
- Distributing layer bundles to other hosts.

## User / Interaction Flow

1. `parbake create --username runner --keychain` builds the base bundle with the agent.
2. `parbake layer --base ~/VM.bundle --bundle ~/Xcode.bundle --script install-xcode.sh` creates the
   layer bundle and runs the script as root in the guest. Its output appears in the terminal.
3. `container run -d --label runtime-macos.bundle=$HOME/Xcode.bundle …` starts a container on base
   and layer.
4. A new Xcode: `parbake layer … --replace` builds a new layer bundle beside the old one and swaps
   it in once the script succeeded.

## Component / Module Specifications

### C-001 — The layer bundle

- A layer bundle holds `Disk.img` as a symbolic link to the base's disk image, `Layer.asif` as its
  own ASIF layer, a new `MachineIdentifier`, and clones of the base's auxiliary storage, hardware
  model and provisioning files.
- `Layer.asif` is created with the base's disk image opened read-only, so its parent UUID is the
  base's layer UUID.
- Booted on its own, the layer bundle opens the base read-only and the layer read-write.
- `MacOSVMBundle.layerBundle(at:)` refuses a layer bundle as its base ("a layer stacks on a base
  bundle only") and a container's instance.

### C-002 — Containers on a layer bundle

- An instance of a layer bundle links `Disk.img` and `Layer.asif` to the files they resolve to,
  and creates `Overlay.asif` on the stack of both opened read-only.
- The guest's disk is base, layer and overlay, with the overlay the only writable level.
- A layer that no longer stacks on its base, or an overlay that no longer stacks on its layer,
  raises `IncompatibleOverlayError`. The label `runtime-macos.on-incompatible-overlay=discard`
  starts the container over on the layer bundle as it is now, as for a rebuilt base.

### C-003 — `parbake layer`

- `--base` defaults to `$PARBAKE_HOME/VM.bundle`, else `~/VM.bundle`. The base needs the guest
  agent, else the command fails and names `parbake agent install`.
- `--script` is a shell script, fed to `/bin/bash -s` as root through the agent. Its standard
  output and standard error appear in the terminal. The script starts once the agent answers,
  which can be before the network is up, so a script that downloads retries.
- A script exiting non-zero fails the command, and the layer bundle is not kept.
- After the script, the guest shuts down through the agent. A guest that does not stop is asked
  like the power button, then stopped forcibly.
- `--replace` builds next to an existing layer bundle and swaps it in on success, as
  `parbake create --replace` does. Without it, an existing path is refused.

## Validation

- **V-1 — passed:** unit tests: the layer's parent is the base, the overlay's parent is
  the layer, a layer on a layer is refused, an instance refuses a layer of another base, resetting
  an instance of a layer bundle keeps the layer.
- **V-2 — passed:** `parbake layer` with a script that installs the Command Line Tools
  through `softwareupdate` created the layer bundle. The base's
  `Disk.img` kept its modification time.
- **V-3 — passed:** a container from the layer bundle ran `xcode-select -p`, reported the installed
  compiler and compiled and ran a C program. A container from the base at
  the same time had no `/Library/Developer/CommandLineTools`.
- **V-4 — passed:** a script that exits 1 failed the command and left no layer bundle.
