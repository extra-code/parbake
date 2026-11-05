# Research: Upstream threads on imageless runtimes and plugin-declared platforms

## Metadata
- Date: 2026-10-30
- Domain: apple/container issues, PRs, discussions (community threads lane)
- Triggered by: .agents/discussions/fork-imageless-runtime.md
- Expires: 2027-04-30

## Direct Answer
Upstream is incrementally moving runtime-specific data out of the API server (ajemory's runtime-abstraction series: #1076, #1548, #1577 merged; #1701 open, no review). No thread proposes or rejects an optional image or plugin-declared platform. The only platform/runtime-selection change merged (#2422, 2026-10-22) infers os/arch/runtime from the OCI image and defaults the handler to `container-runtime-<os>`, i.e. it keeps the image as the source of truth. Maintainers accept small-to-medium, staged PRs that keep the on-disk bundle and old containers working; opaque `runtimeData` is the sanctioned extension channel.

## Sources
- https://github.com/apple/container/pull/1701 (open, 2026-06-11)
- https://github.com/apple/container/issues/1376, /1377 (2026-04-01, open, no comments)
- https://github.com/apple/container/pull/1076, /1548, /1577, /1323, /1618, /2422, /2393
- https://github.com/apple/container/issues/1398, /1569, /1565, /2392
- https://github.com/apple/container/discussions/1336, /611, /1673
- https://github.com/apple/containerization/issues/624

## Findings
- #1701 "Add runtime abstraction plumbing" (ajemory, opened 2026-06-11, still open, +342/-225, 16 files, label cli). Described as "part 1 of 2" of #1376. Zero reviews, zero review comments; only the coverage bot. Last updated 2026-06-12. Diff scope: kernel and initfs removed from `ContainersService.create`; `containerConfigFromFlags` now returns `(config, kernel, initImageRef)` so the CLI encodes `LinuxRuntimeData`; `runtimeData` changes from optional to required (`create(configuration:options:runtimeData:)`, XPC key required); `RuntimeConfiguration` shape changes. The diff removes the `kernel.platform` system-platform lookup and the image-snapshot/`initImage` handling from `ContainersService.create`; the diff shows no edits to the `ContainerConfiguration.image` or `platform` types, and no `PluginConfig` change. Bundle shape unchanged; old unstarted containers read via a back-compat path.
- #1376 (APIServer) and #1377 (CLI), both ajemory 2026-04-01: "APIServer requires runtime information that's not necessarily required for all runtimes... allows plugins to handle runtime specifics". #1377: "better user experience where multiple plugins/runtimes are involved". No comments, no assignee discussion.
- #1076 (ajemory, 2026-01-22 to merged 2026-02-14, +295/-34, 7 files): bundle creation moved from ContainersService to SandboxService. ~3 weeks, ~24 review events, nearly all katiewasnothere (approver), also JaewonHur, jglogan, dcantah (fmt). Asks: avoid loading config twice, write metadata into the bundle dir, nits on error-message casing, defer an ID-to-service-label mapping as TODO for a follow-up. Tests were added.
- #1398 (2026-04-06, closed): user hit `container create` no longer provisioning rootfs after #1076. katiewasnothere 2026-04-13 replied it was "an intentional decision... move as much runtime-specific code from our core services... to the runtime implementation... enable people to write runtime plugins". Stated direction: runtime plugins are an explicit goal. The same change produced user-visible regressions (see #2392, closed by #2393).
- #1548 "Add `variant` Support" (ajemory, merged 2026-05-13, +99/-15, jglogan approved, merged by jglogan): introduced opaque `RuntimeConfiguration.data` and `LinuxRuntimeData`. Body: "idea is to eventually move all runtime specific data into the `data` field so that the APIServer is only aware of generic container information." jglogan asked for `bootstrap()` to create an empty runtime config if missing "for a few releases" (compat concern).
- #1577 "Reorganize runtime targets for scalable plugin support" (ajemory, merged same day 2026-05-20, +217/-196, 20 files, katiewasnothere approved, self-merged).
- #1569 (jglogan, closed 2026-05-16): `LinuxRuntimeData` lives in an executable target, so API-client callers cannot encode it; fixed by the target reorg. Shows API-client public-surface concerns are noticed by maintainers.
- #1565 (jglogan, closed): maintainers define "runtime" as the part that manages a running container (a runtime plugin); config file renamed away from `runtime-config.toml`.
- #1323 rootFsOverride (JaewonHur, 2026-03-17 merged 2026-03-18, +17/-7, 3 files, jglogan approved, author self-merged, no tests, one-day turnaround): adds `ContainerCreateOptions.rootFsOverride`; ContainersService skips `getCreateSnapshot` when it is set. Precedent for a create path that does not need an image snapshot, though `configuration.image` is still required.
- #1618 (Cyb3rDudu, opened 2026-05-29, open, +106/-1, 4 files incl. test): user plugin dir. No reviews; author bumped jglogan 2026-07-12. Illustrates external contributors waiting >4 months.
- #2422 "Infer platform and runtime from OCI image" (noah-thor, 2026-10-20 to merged 2026-10-22, +303/-113, 17 files, JaewonHur approved, self-merged, tests added in PlatformResolverTests/DefaultPlatformTests). Adds `--runtime` (help text: "Set the runtime handler for the container (default: container-runtime-<os>)"); `config.runtimeHandler = management.runtime ?? "container-runtime-\(os)"`; error "unable to locate runtime plugin ...; pass --runtime". Platform still comes from the image index/manifest. JaewonHur review asks: docs for the convention, clearer error message; query whether `--rosetta` should default on for x86_64.
- #2393 (bryanmosley, issue #2392; 2026-10-15 created and merged in ~3 h, +167/-3, jglogan approved/merged): treats missing log files as empty "or whose runtime writes no boot log"; an outside contributor explicitly framing non-Linux-style runtimes as a supported case, merged quickly.
- Discussion #1336 (katiewasnothere, 2026-03-20): config system -> TOML; noah-thor PRs #1422 (plugin `config.json` -> `config.toml`, JSON still read with warning) and #1425. Shows deprecation path style: backwards-compatible with warning, removal later as a declared breaking change.
- Discussion #611 (jbschooley, 2025-08-02) macOS in containers: egernst 2025-08-07: "Today ... this project focus just on Linux based container workloads." containerization #624 (2026-03-31, open): macOS containers on macOS, +1s only, no maintainer reply. Neither contains a design.
- Discussion #1673 (jshi991, 2026-06-09) k8s plugin: jglogan gives product-scope feedback (2026-06-17) and plugin proceeds as CLI plugin built on regular images; no runtime/platform discussion.
- Review norms: reviewers seen are katiewasnothere, jglogan, JaewonHur, dcantah; merges by jglogan, ajemory, JaewonHur, noah-thor (often author self-merge after one approval). Tests: added in runtime/platform PRs (#1076, #1548, #2422), omitted in #1323. `make fmt` and hawkeye license-header checks are enforced (#1076). PR template has "Breaking change" checkbox; breaking changes get compat shims (#1548, #1422, #1701 old-container path). Turnaround for core members: 0-3 weeks; for outside PRs: weeks to months or none (#1618, #1701).

## negative
- No issue, PR or discussion in apple/container (2026) proposes making `ContainerConfiguration.image` optional, an "imageless" runtime, or plugin-declared platform/OS; searches "imageless", "image optional", "platform resolution", "ls OS column", "non-Linux", "macOS guest" returned nothing relevant.
- No thread rejects it either.
- No review comments on #1701 and no comments on #1376/#1377.
- No `PluginConfig` field for platform/OS found in any thread; #1422 migrates its format only.
- Discussion #1336 and #1673 numbers do not resolve as issues (they are discussions; read via GraphQL).

## leads
- Ask upstream via #1376/#1377 (open, maintainer-authored by ajemory) before proposing; #1701 is part 1 of 2, part 2 is not yet visible.
- #2422's `PlatformResolver.swift` and `--runtime` flag are the current seam for runtime/platform selection; any plugin-declared platform proposal collides with it (merged 2026-10-22).
- #1323 `rootFsOverride` as precedent for skipping image snapshot.
- Fork code to compare: /Users/christian/workspace/apple/extra-code/container-fork.
- Candidate maintainers to engage by login: ajemory, jglogan, katiewasnothere, noah-thor, JaewonHur.
