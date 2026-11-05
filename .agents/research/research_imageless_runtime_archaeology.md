# Research: Fork patch history and constraints for an imageless runtime patch

## Metadata
- Date: 2026-10-30
- Domain: extra-code/container fork history, Parbake fork policy, apple/container exposure
- Triggered by: .agents/discussions/fork-imageless-runtime.md
- Expires: 2027-04-30

## Direct Answer
The fork has three runtime-plugin commits on `parbake` (+231/-66, +3, +4/-4 lines) on base apple/container 804209b1. All are justified as one feature: let a runtime plugin skip kernel, init image and image snapshot. `container run` still resolves and fetches an image and takes os/arch/runtime from it (apple/container#2422 landed in the base); the macOS plugin ignores the image. Apple has seen no patch: the only fork PR, #2438, was packaging, opened by mistake and closed. Earlier decisions treat the fork as temporary, and prefer no fork patch where upstream suffices.

## Sources
- fork: `git log main..parbake`, `main..ocx-package`; tags `parbake-804209b1`, `ocx-1.6.1_01`
- docs/adr/adr_0015_ship_the_fork_and_parbake_as_two_ocx_packages.md; CONTRIBUTING.md; AGENTS.md; docs/quickstart.md:92,231
- .agents/discussions/fork-container-ocx-delivery.md; scripts/package.sh; config.toml; Package.resolved
- gh: apple/container PR 2438, 2422; author listing

## Findings
1. Commits on parbake (not main), oldest first:
   - 3b9b5b75 "Let runtime plugins opt out of kernel, init image and image snapshot": 9 files, +231/-66. Adds `[runtimeConfig]` (requiresKernel, requiresInitImage, requiresImageSnapshot, default true) in PluginConfig.swift; skips artifacts in Utility.swift and ContainersService.swift; kernel and initialFilesystem become optional in RuntimeConfiguration and the create XPC message; container-runtime-linux still requires both. Tests: PluginConfigTest.swift +65, RuntimeConfigurationTests.swift +28.
   - 13ff2d85 "Warn when kernel flags are ignored by the runtime": Utility.swift +3. No test.
   - 0f824548 "Read the container configuration on exit without the runtime bundle": ContainersService.swift +4/-4 (uses `getContainerConfiguration(at:)`). No test.
   Not in `main..parbake` but on `ocx-package`: 3d04f93d (workflows, ocx/README.md, metadata.json, source-revision, scripts/ocx-package.sh +880), c6c73c33 (workflow, 2 lines).
   Fork main head is 804209b1 (#2428); #2422 (infer os/arch/runtime from the image, bumps containerization 0.53.0) is in the base.
2. Docs. ADR 0015 says "four patches" (l.32) where AGENTS.md:87 and git show three; the fork "is temporary ... an Apple release replaces it" (l.40); upstream disclaimer "Temporary until upstream ships the patches" (l.353); on release the package root is marked deprecated (l.373). Option C (fork patch for an extra plugin directory) was rejected: "diff grows by a patch Apple may not take" (l.126-127). The ocx delivery discussion (l.20-22, 90) rejected a label patch as "a permanent fork change Apple does not need". No numeric limit on patch count was found. Tag scheme: upstream version + `_NN`, starts 01, resets on upstream bump (ADR l.174; fork ocx/README.md l.38). Pin: Package.resolved revision 0f8245481903d4db3fe701bbf0750924b450bc4d; `packaging/container.tag` = `1.6.1_01`; `ocx/source-revision` at tag `ocx-<tag>` must equal that revision (ADR l.206-239; CONTRIBUTING.md:53-55). A new upstream version needs a CHANGELOG line about resetting `~/.parbake/app` (CONTRIBUTING.md:67). Fork ocx/README.md: "temporary patched build ... goes away once Apple ships the patches".
3. Upstream. Author extra-code has exactly one PR (#2438) and no issues in apple/container (confirmed with --json author filter; the earlier plain listing included unrelated PRs from the search). #2438 "Ocx package": extra-code:ocx-package, +1465 lines, 15 files, closed 2026-10-29 unmerged. jglogan: the repo "doesn't include any additional packaging beyond what's necessary to create the pkg installer". extra-code replied it was opened by mistake from the fork banner and OCX packaging stays in the fork. The PR template says non-trivial PRs need a prior issue. No upstream issue or PR found that mentions the runtime-plugin patches (searches: runtimeConfig, requiresKernel, extra-code/container).
4. Plugin. config.toml sets `[runtimeConfig]` all three false. Sources/container-runtime-macos/RuntimeService.swift reads only `containerConfiguration` (mounts, ports, labels, resources, id); no use of config.image or config.platform. Platform in Sources appears only as VZMacPlatformConfiguration. Fork side: `containerConfigFromFlags` still calls `ClientImage.platforms` and `ClientImage.fetch` for the image argument and resolves os/arch via PlatformResolver before reading the runtime's requirements; the runtime handler defaults to `container-runtime-<os>` from the image. The image therefore is still required, the guest shows `linux arm64` from a placeholder image (docs/quickstart.md:231).
5. Release flow for a further patch: commit on `parbake`; new fork tag/commit; set `ocx/source-revision` on `ocx-package`; tag `ocx-1.6.1_02` (workflow ocx-package.yml publishes); bump `packaging/container.tag`; regenerate `Package.resolved` with `/usr/bin/swift package resolve` and update Package.swift pin (AGENTS.md:37,87); scripts/package.sh pairing check compares source-revision to the pin (fixtures for _01 to _04 exist); AGENTS.md:42-45 requires `task e2e:package` (attended, about 30 minutes, stops stock services) for a pin or packaging change; ADR 0015 and ADR 0012 mention the patched fork; docs wording "three/four patches" needs updating.

## negative
- No stated cap on patch count or size; no written upstreaming plan beyond "temporary".
- No upstream issue for the patches; Apple has not commented on them.
- No test for commits 2 and 3.

## leads
- ADR 0015 "four patches" versus three commits: unreconciled.
