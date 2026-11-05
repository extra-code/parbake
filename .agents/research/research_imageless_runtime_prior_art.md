# Research: Prior art for workloads that do not run from an OCI image

## Metadata
- Date: 2026-10-30
- Domain: container runtimes, orchestrators, apple/container plugin model
- Triggered by: .agents/discussions/fork-imageless-runtime.md
- Expires: 2027-04-30

## Direct Answer
- apple/container already has runtime plugins and a `--runtime` flag. The default is `container-runtime-<os>`. Docs say `--os` defaults "from image, else linux".
- Maintainers started a "runtime abstraction" in 2026: issues #1376 and #1377 (2026-04-01) and PR #1701 (2026-06-11, open). It removes Linux kernel and initfs data from the API server. No maintainer reply on those threads.
- The only maintainer statement on macOS guests is from 2025-08-07 (discussion #611): both repos "focus just on Linux based container workloads". Nothing newer found.
- Other stacks keep the image and the runtime apart. A runtime handler in container daemons and orchestrators picks the shim. The image only supplies a rootfs. Sandbox-only and rootfs-only paths exist. Common container CLIs and the OCI runtime spec treat a root filesystem as required in most cases.
- No source found that records a guest OS in a listing for an image-less workload.

## Sources
- https://github.com/apple/containerization/blob/main/CONTRIBUTING.md
- https://github.com/apple/container/issues/1376 , /1377
- https://github.com/apple/container/pull/1701
- https://github.com/apple/container/issues/1398 (comment by katiewasnothere, 2026-04-13, cites PR #1076)
- https://github.com/apple/container/pull/1076
- https://github.com/apple/container/issues/2392
- https://github.com/apple/container/issues/1565
- https://github.com/apple/container/discussions/611
- https://github.com/apple/container/discussions/868 , /1673 , /1336
- https://github.com/apple/container/pull/1662
- https://github.com/apple/container/pull/1323
- https://github.com/apple/container/pull/1618
- https://github.com/apple/containerization/issues/624
- https://github.com/apple/containerization/issues/321 , PR 416 , PR 936
- https://github.com/apple/container/blob/main/docs/command-reference.md
- https://github.com/apple/container/blob/main/Sources/ContainerPlugin/PluginConfig.swift
- https://raw.githubusercontent.com/opencontainers/runtime-spec/main/config.md

## Findings

### 1. apple/container and apple/containerization
- Plugin kinds. `PluginConfig.swift` defines runtime, network, core and auxiliary daemon plugins. A runtime plugin "provides an XPC API through which the lifecycle of a single container can be managed". Plugin config moved from `config.json` to `config.toml` (discussion #1336, PR #1422, 2026-04).
- `--runtime` exists. Command reference: "Set the runtime handler for the container (default: container-runtime-<os>)". `--os`: "default: from image, else linux". `--platform` overrides `--os` and `--arch`.
- Runtime abstraction. #1376 "Runtime Abstraction - APIServer" says the API server "requires runtime information that's not necessarily required for all runtimes". #1377 covers the CLI. Both opened 2026-04-01 by the same author, no comments. PR #1701 (2026-06-11, +342/-225, 16 files, open) moves kernel and initfs out of ContainersService.
- Earlier step. PR #1076 (merged 2026-02-14, +295/-34, 7 files) moved bundle creation into the sandbox service. Maintainer comment on #1398 (2026-04-13): the aim was to move "as much runtime-specific code" out of core services into the runtime.
- Issue #2392 (2026-10-15) says a runtime that writes no boot log breaks `container logs`. It names `RuntimeLinux` as the only runtime that writes `vminitd.log`.
- Issue #1565 notes "runtime" means a runtime plugin in project terms.
- PR #1323 (merged 2026-03-18, +17/-7) added `rootFsOverride` to `ContainerCreateOption`. The container then uses that root fs instead of the image snapshot clone.
- macOS guests. Discussion #611 (2025-08-02, 18 comments). Maintainer egernst, 2025-08-07: "Today ... this project focus just on Linux based container workloads." A commenter points to Virtualization.framework (2025-09-03). containerization #624 (2026-03-31, open) asks for macOS containers on macOS. No maintainer reply.
- Maintainers do build non-container surfaces on the same stack. Discussion #868 (2025-11-12) proposed `distro`. PR #1662 added `container machine` (merged 2026-06-08, +5125/-36, 51 files). It still uses OCI images.
- Plugin discussions. `k8s` plugin discussion #1673 (2026-06-09) and PR #2416 are open. Maintainer jglogan commented 2026-06-17. PR #1618 (user plugin dir, 2026-05-29) is open; the author pinged for a reply on 2026-07-12.
- containerization OCI runtimes. Issue #321 (2025-10-08) then PR #416 (merged 2025-11-21, +848/-80, 20 files, "experimental OCI runtime support"). PR #936 merged 2026-09-24 (+631/-22).
- CONTRIBUTING (shared by both repos). Use Discussions for open-ended ideas. Then open a clear issue. Share a plan and wait for maintainer acknowledgment before code for non-trivial changes. "Pull requests that skip these steps may be deprioritized." Commits must be signed. Squash merge. AI use is allowed if the author can explain every line. No design-doc template is required.

### 2. A container daemon
- Runtime handlers are a map keyed by the handler name. Each names a runtime shim, for example a plain one or a VM-based one. The orchestrator's runtime class selects the key.
- `sandboxer` defaults to `podsandbox`, which makes a pause container. A custom sandbox controller can come from a shim or a proxy plugin of type "sandbox".
- A per-runtime `snapshotter` override exists and is marked experimental. A per-runtime `disable_pause_image_pull` option is listed.
- The runtime interface passes the handler as an annotation on the sandbox config, which can select a snapshotter per handler.
- I did not find a per-handler platform field in the config doc.

### 3. A cluster orchestrator
- RuntimeClass selects "container runtime configuration". It carries `overhead` and `scheduling.nodeSelector`. The page does not say it changes image or platform rules.
- `.spec.os.name` is `linux` or `windows` only. The node agent refuses a workload whose value does not match the node. The scheduler does not use it, so users add an OS node selector.
- No `darwin` value exists in that list.

### 4. Container CLIs and the OCI runtime spec
- A common container CLI: `run [OPTIONS] IMAGE ...`, so IMAGE is required. `--platform` is for multi-platform servers. `scratch` is "an explicitly empty image" and is reserved: you cannot pull, run or tag it.
- A daemonless container CLI: `--rootfs` takes "an exploded container on the file system". Docs: "run a container without requiring any image management". `--platform`, `--os`, `--arch` apply to "selecting the image".
- OCI runtime spec: `root` is REQUIRED on all platforms except Hyper-V containers on Windows, where it MUST NOT be set. A `vm` object exists for hardware-virtualized targets.

### 5. VM-based runtimes
- VM-based runtimes behind a container daemon use a runtime class plus a guest kernel and guest image. The container rootfs reaches the guest over virtio-9p or virtiofs. Those sources are secondary.
- I could not confirm how any of these show the guest OS in a listing.

## negative
- No apple/container or apple/containerization issue, PR or discussion for "image optional", "without image", "platform override", "requiresKernel", "macOS guest" or "darwin" as a runtime.
- No search hit for a code string `requiresKernel` in apple/container.
- No maintainer comment on #1376, #1377 or #1701.
- No maintainer statement on macOS guests after 2025-08-07.
- No design-doc requirement in CONTRIBUTING.
- The orchestrator's pages did not state how a runtime class changes image or platform rules.
- The container daemon's sandbox API doc was not retrievable. No platform field appears in its runtime config doc.
- No official page of a VM-based runtime found on guest-OS display in listings. A VM manager's `list` doc did not show an OS column.
- No feature of the common container CLI found that runs a container with no image.

## leads
- Read PR #1701 diff and any review threads for how `RuntimeConfiguration` is shaped and which fields stay Linux-only.
- Read PR #1076 for the bundle-creation move.
- Check Sources/ContainerPlugin in the fork for fields a runtime plugin can declare.
- Ask in a Discussion first (CONTRIBUTING), then an issue linking to it.
- Read `config-vm.md` in the OCI runtime spec.
- Read the orchestrator's design note for its OS field.
