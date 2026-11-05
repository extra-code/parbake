# Discussion: Fork patch for runtime plugins that need no image

State: handed-off → plan · Updated: 2026-10-30
Ratified: 2026-10-30 → plan
Confidence: ratified by the user; research vintages 2026-10-30 (recon, prior art, upstream threads, archaeology)

## Problem

`container run` and `container create` in apple/container (and in the fork extra-code/container)
always resolve, fetch and read an OCI image. Parbake's runtime plugin `container-runtime-macos`
boots a macOS guest from a VM bundle passed as the label `runtime-macos.bundle` and never uses the
image. Users therefore pass a placeholder (`alpine`), `container` pulls it from docker.io (and may
ask the keychain for a stored registry login), and `container ls` shows the placeholder's platform
(`linux`/`arm64`) for a macOS guest. Goal: a fork patch that lets a runtime plugin declare that it
needs no image and which platform it runs, cut so that apple/container can take it upstream.

## Related

- Fork code (branch `parbake`): `Sources/Services/ContainerAPIService/Client/Utility.swift`
  (`containerConfigFromFlags`), `Sources/ContainerPlugin/PluginConfig.swift` (`RuntimeConfig`),
  `Sources/ContainerResource/Container/ContainerConfiguration.swift`,
  `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`,
  `Sources/ContainerCommands/Container/ContainerRun.swift`, `ContainerCreate.swift`,
  `ManagedContainer+ListDisplayable.swift`.
- Existing fork patch this extends: `3b9b5b75` "Let runtime plugins opt out of kernel, init image and
  image snapshot" (`requiresKernel`, `requiresInitImage`, `requiresImageSnapshot`).
- Parbake: `config.toml` `[runtimeConfig]`, `docs/quickstart.md`, `README.md` (placeholder image),
  `docs/adr/adr_0015_ship_the_fork_and_parbake_as_two_ocx_packages.md`.
- Upstream: apple/container PR #1701 (runtime abstraction, open), issues #1376/#1377, CONTRIBUTING
  (plan acknowledged by a maintainer before non-trivial code).

## Research

- Codebase recon (2026-10-30, inline in this file):
  - The image is used for three things: platform resolution (`ClientImage.platforms` +
    `PlatformResolver`, which also picks the default runtime `container-runtime-<os>`), process
    defaults (`Parser.process(config:)`, already nil-tolerant), and the reference stored in
    `ContainerConfiguration.image` (non-optional; read by `ls`, `getActiveImageReferences`/disk usage,
    `image prune --all`, `commit`, the builder).
  - `ContainerConfiguration.platform` decodes with a default, so a plugin-declared platform needs no
    schema change. `requiresImageSnapshot=false` already skips the server-side snapshot.
  - Size: (A) `requiresImage=false` + plugin platform, image argument still required but not
    fetched — about 5 files, 60–100 lines, no schema change. (B) image argument optional — about
    12–14 files, 150–250 lines, `ContainerConfiguration.image` becomes optional (old binaries cannot
    read such configs; positional parsing clashes with passthrough arguments).
- Prior art: `.agents/research/research_imageless_runtime_prior_art.md`.
- Upstream threads and review norms: `.agents/research/research_imageless_runtime_upstream_threads.md`
  (no thread proposes or rejects an optional image or a plugin-declared platform; PR #2422, merged
  2026-10-22, infers platform and runtime from the image via `PlatformResolver` and `--runtime`,
  the seam this patch touches; PR #1701 runtime abstraction is open without review; maintainers
  stage work as "part N of M" with tests and back-compat shims).
- Fork patch history: `.agents/research/research_imageless_runtime_archaeology.md` (three commits on
  `parbake`; ADR 0015 still says "four patches"; a further patch means `ocx-1.6.1_02`, a
  `packaging/container.tag` bump, a new pin, the pairing check and an attended `task e2e:package`).

## Decisions

- Scope: variant A now — a runtime plugin that needs no image makes `container run`/`create` skip
  image resolution and fetch; the image argument stays required. Variant B (image argument
  optional) follows later as its own proposal; this discussion documents B fully so a later agent
  can implement it.
- Platform source: a static field in the plugin's `config.toml` `[runtimeConfig]` (for Parbake
  `darwin/arm64`), same pattern as `requiresKernel` and the other flags.
- Image field in variant A: a fixed placeholder in `ContainerConfiguration.image`, whatever the
  user passed. Strongest counter-argument, named once: Apple has to accept a special value that
  `ls`, `image prune`, disk usage and `commit` now meet; variant B removes it later.
- Interface: `container run`/`create`, not `container machine`. Machines also require an image
  (`MachineCreate.swift`, `MachineConfiguration.image`), hard-code a Linux platform
  (`MachinesService.swift:325`), boot a Linux kernel with a Linux init and user setup, run on top
  of `ContainerClient`, and have no runtime-plugin seam. Parbake's model — an ephemeral guest from
  a base bundle plus an overlay — is container semantics; a machine is a long-lived VM.
- Placeholder spelling: `<none>`, the spelling common container CLIs use for "no image" in listings.
- Platform precedence: the plugin's declared platform wins; a `--platform`, `--os` or `--arch` that
  contradicts it fails with a clear error instead of a silent choice.
- Upstream order: build the patch in the fork, prove it with Parbake (`task e2e:package` and
  `task e2e:package:candidate`), then open a Discussion at apple/container that links issue #1376
  and the fork as a running example; a PR only after a maintainer agrees (CONTRIBUTING).

## Requirements

Variant A, fork extra-code/container, branch `parbake`:
- `PluginConfig.RuntimeConfig` gains `requiresImage` (decode default `true`) and an optional
  `platform` (string `os/arch[/variant]`, decode default absent). `requiresImage = false` without a
  `platform` is a plugin config error at load.
- `Utility.containerConfigFromFlags`: when `--runtime` names a plugin with `requiresImage = false`,
  skip `ClientImage.platforms`, `PlatformResolver` and `ClientImage.fetch`; set `config.platform`
  from the plugin; build the process with `Parser.process(config: nil)`; store an
  `ImageDescription` whose reference is `<none>` (descriptor fields empty or a fixed null digest,
  decided in the plan). Without `--runtime`, behaviour is unchanged (the default runtime still comes
  from the image's OS, PR #2422).
- A `--platform`, `--os` or `--arch` that differs from the plugin's platform fails before any work.
- `ContainersService` skips `ClientImage(description:)` for such a config. `image prune`,
  `getActiveImageReferences`/disk usage and `commit` treat `<none>` as no image (no "in use" entry;
  `commit` refuses with a message that names the runtime).
- `container ls` shows `<none>` and the plugin's OS and arch.
- Tests: `PluginConfigTest` (decode defaults, the config error), a CLI test for the skipped fetch
  and the platform conflict, and unit tests for the `<none>` handling in prune and commit.

Variant A, Parbake:
- `config.toml` `[runtimeConfig]`: `requiresImage = false`, `platform = "darwin/arm64"`.
- Quickstart, README and the end-to-end checklist: the image argument stays (CLI requirement), but
  nothing is pulled and `ls` shows `<none> darwin arm64`. Which placeholder the docs pass is decided
  in the plan.
- `scripts/package-e2e.sh`: E13 no longer pulls `alpine`; E14 checks `darwin`/`arm64` in `ls`.
- Release flow for the fork patch: commit on `parbake`, `ocx/source-revision` and tag
  `ocx-1.6.1_02` on `ocx-package`, `packaging/container.tag` and the `Package.resolved` pin in
  Parbake, the pairing check in `scripts/package.sh`, and the attended e2e runs (AGENTS.md).

Variant B, documented for a later agent (not built now; the self-contained version is
`.agents/discussions/fork-imageless-runtime-b.md`, State parked):
- `container run`/`create` accept a missing image when `--runtime` names a plugin with
  `requiresImage = false`. A positional optional image clashes with the passthrough arguments
  (`ContainerRun.swift:59-60`, `ContainerCreate.swift:52-53`); candidate shapes are an `--image`
  flag with the positional kept for compatibility, or a `--no-image` flag. The plan for B picks one.
- `ContainerConfiguration.image` becomes `ImageDescription?` with `decodeIfPresent`; writers omit it
  for image-less containers. Old binaries cannot decode such configs, so B ships behind the usual
  upstream back-compat staging (read-tolerant first, writers later).
- Nil handling at `ContainersService.swift:260,348-350`, `ImagePrune.swift:45`,
  `ContainerCommit.swift:47`, `BuilderStatus.swift:95`, `Builder+Start.swift:87,206`,
  `ManagedContainer+ListDisplayable.swift:28`, and `ContainerConfigurationTests.swift`.
- The `<none>` placeholder from A goes; `ls` shows an empty IMAGE column or `<none>` from the nil.
- Estimated size: 12–14 files, 150–250 lines (recon 2026-10-30).

## Out of scope

- `container machine` (Linux-only, see Decisions).
- Variant B's implementation (documented above only).
- Opening anything at apple/container before the fork patch passes the Parbake e2e runs.
- Changes to the runtime abstraction of PR #1701 or to `runtimeData`.

## Open questions

- [NEEDS CLARIFICATION: does anything in the API server, network or rosetta code gate on
  `config.platform.os == "linux"`, so that `darwin` breaks a path today?]
  Recommended: grep the fork for `.os ==`, `linux` and `platform.os` in the plan's discover phase
  and list each site.
- [NEEDS CLARIFICATION: which image argument do Parbake's docs pass once nothing is pulled?]
  Recommended: keep `alpine` until variant B, so commands stay copy-pasteable on stock and fork
  builds alike — the plan confirms the CLI accepts any reference without a fetch.
- [NEEDS CLARIFICATION: ADR 0015 says "four patches", the fork carries three.]
  Recommended: correct the count in the same plan, since the new patch changes it anyway.

## Verification

- Fork: `swift test` for the new and touched tests; the fork's own CI on `parbake`.
- Parbake: `task check`; an attended `task e2e:package:candidate` run against a locally built fork
  package, then `task e2e:package` after the `ocx-1.6.1_02` release. E13 shows no image pull, E14
  sees `darwin`/`arm64`, and no registry-login dialog appears.
- Manual: `container ls` on a running guest shows `<none>` and `darwin arm64`; `container run` with
  `--platform linux/arm64` and `--runtime container-runtime-macos` fails with the conflict error.
