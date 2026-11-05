# Discussion: Optional image argument for runtime plugins that need no image (variant B)

State: parked · Updated: 2026-10-30

## Problem

apple/container's `container run` and `container create` require an image argument and store it as
the non-optional `ContainerConfiguration.image`. A runtime plugin that boots something else, such
as Parbake's `container-runtime-macos`, which boots a macOS VM bundle passed as the label
`runtime-macos.bundle`, has no image to name.

Variant A (`.agents/discussions/fork-imageless-runtime.md`) lets such a plugin declare
`requiresImage = false` and its own `platform` in `config.toml`. `container` then skips the image
fetch, takes the platform from the plugin, and stores the fixed placeholder reference `<none>`. The
image argument stays required, so users still type a placeholder such as `alpine`.

Variant B removes that last step: no image argument at all for such a plugin, and no image in the
stored configuration. B builds on A: it reuses `requiresImage` and the plugin `platform`, and it
retires the `<none>` placeholder.

## Related

- Variant A discussion and decisions: `.agents/discussions/fork-imageless-runtime.md`.
- Research (2026-10-30):
  - `.agents/research/research_imageless_runtime_prior_art.md`;
  - `.agents/research/research_imageless_runtime_upstream_threads.md`;
  - `.agents/research/research_imageless_runtime_archaeology.md`.
- Fork extra-code/container, branch `parbake`. Line numbers come from the 2026-10-30 recon and may
  drift by a few lines:
  - `Sources/ContainerCommands/Container/ContainerRun.swift:59-60` and `ContainerCreate.swift:52-53`
    declare `@Argument(help: "Image name") var image: String` before a passthrough `arguments`
    array.
  - `Sources/Services/ContainerAPIService/Client/Utility.swift:70-285`
    (`containerConfigFromFlags`): image platforms, `PlatformResolver`, fetch, image config,
    `ContainerConfiguration(id:image:process:)`.
  - `Sources/ContainerResource/Container/ContainerConfiguration.swift`: `image: ImageDescription`
    (L24), decoded with `decode` (L110), required by the init (L187); `platform` decodes with a
    default (L44, L126).
  - Consumers of `configuration.image`: `ContainersService.swift:260` (`getActiveImageReferences`,
    read by `DiskUsageService.swift:41`), `ContainersService.swift:348-350`, `ImagePrune.swift:45`,
    `ContainerCommit.swift:46-47`, `BuilderStatus.swift:95`, `Builder+Start.swift:87,206`,
    `ManagedContainer+ListDisplayable.swift:22-30`, `MachinesService.swift:642` (constructs a
    config), and `Tests/ContainerResourceTests/ContainerConfigurationTests.swift:48`.
- Upstream context: PR #2422 (merged 2026-10-22) infers platform and runtime from the image; PR
  #1701 (runtime abstraction, open) and issues #1376/#1377; PR #1548 introduced the opaque
  `RuntimeConfiguration.data`. Maintainers stage compatibility changes read-tolerant first, writers
  later, and keep a fallback "for a few releases".
- Parbake: `config.toml` `[runtimeConfig]`, `docs/quickstart.md`, `README.md`,
  `docs/end_to_end_checklist.md`, `scripts/package-e2e.sh` (steps E13 and E14).

## Requirements

- Precondition: variant A is merged in the fork and in use by Parbake.
- CLI: `container run` and `container create` accept no image when `--runtime` names a plugin with
  `requiresImage = false`. Every other runtime still requires an image, with today's error.
- Stored configuration: `ContainerConfiguration.image` becomes `ImageDescription?`, decoded with
  `decodeIfPresent`; a writer omits it for an image-less container. Existing configs keep decoding.
- Compatibility: binaries older than B cannot decode a config without `image`. B therefore lands in
  two steps: first every reader tolerates a missing image, then writers stop writing the `<none>`
  placeholder. Between the steps, writers keep `<none>`.
- Every consumer listed under Related handles `nil`:
  - `ls` shows an empty IMAGE column, or `<none>` rendered from `nil`;
  - prune and disk usage skip it;
  - `commit` refuses with a message that names the runtime;
  - the builder paths keep requiring an image.
- `--format json` of `container ls`/`inspect` omits `image` for such containers. This is documented
  as a change for API consumers.
- Parbake: docs and the e2e script drop the placeholder argument; E13 starts the guest without an
  image argument.
- Tests: decode of old and new configs, each nil consumer, the CLI with and without an image for
  both kinds of runtime.
- Estimated size: 12–14 files, 150–250 lines.

## Open questions

- [NEEDS CLARIFICATION: CLI shape for "no image". A positional optional argument clashes with the
  passthrough arguments.]
  Recommended: an `--image <ref>` option next to the kept positional, where neither is required for
  a `requiresImage = false` runtime. Reason: old command lines keep working, and the
  parse is unambiguous. Alternative: a `--no-image` flag, which is smaller but reads as a negation
  users must remember.
- [NEEDS CLARIFICATION: is B one upstream proposal with A, or a follow-up after A is accepted?]
  Recommended: a follow-up, referencing the A discussion at apple/container. Reason: A stays small
  and reviewable, and B touches the public `ContainerResource` type.
- [NEEDS CLARIFICATION: how does `ls` render a missing image?]
  Recommended: `<none>`, matching A. Reason: users see no change between A and B.

## Out of scope

- Variant A itself (see its discussion).
- `container machine`, which is Linux-only and requires an image by design.
- Changes to the runtime abstraction of PR #1701 or to `runtimeData`.

## Verification

- Fork: `swift test` with the new decode and consumer tests; a config written by a pre-B build
  still decodes; `container run --runtime container-runtime-macos --label runtime-macos.bundle=…`
  without an image starts a guest; the same without `--runtime` fails with the image-required error.
- Parbake: `task check`; attended `task e2e:package:candidate` against a locally built fork
  package, then `task e2e:package` after the fork release; E13 runs without an image argument.
- Docs: the quickstart, the README and the checklist contain no placeholder image.

## Next

Resume with `/hex-discuss .agents/discussions/fork-imageless-runtime-b.md`, or plan directly with
`/hex-plan "Optional image argument for image-less runtime plugins, per
.agents/discussions/fork-imageless-runtime-b.md"` once variant A has landed.
