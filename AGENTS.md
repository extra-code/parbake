# Parbake — agent context

Parbake is `container-runtime-macos`, a runtime plugin for Apple `container` that boots
ephemeral macOS guests on Apple silicon through Virtualization.framework: each container
boots its own instance of a macOS VM bundle, and the instance is discarded with the container.

## Product

- **What:** the macOS counterpart to `container-runtime-linux`. `container run --runtime
  container-runtime-macos` boots a macOS guest whose lifetime is the container's.
- **Users:** Mac mini CI hosts whose CI executors start macOS jobs through this runtime;
  developers testing macOS guests locally.
- **Related repos:** apple/container, through the fork
  [extra-code/container](https://github.com/extra-code/container) (tag `parbake-804209b1`, the
  runtime-plugin hooks this plugin builds against); apple/containerization.
- **Research keywords:** Virtualization.framework, `VZMacOSBootLoader`, `VZMacHardwareModel`,
  `VZMacMachineIdentifier`, `VZMacGuestProvisioningOptions`, IPSW restore image, APFS
  `clonefile`, virtio vsock, virtiofs, container runtime plugin, XPC.

## Verification

Run `task check` before considering a change complete: it lints Swift and shell sources, builds,
signs three executables, and runs the Swift tests. The plugin and `parbake` carry the
virtualization entitlement; `parbake-agent` is signed without it.
`task` and the lint tools come from OCX (`ocx.toml`); `task setup` renders the toolchain. In a hex run (a
/hex-execute pipeline or step), the run's integration and release gates satisfy "verify before
commit"; commits use `--no-verify`.

- Coverage: `task coverage` prints line coverage per module. It reports only and sets no threshold.
- Selective tests: `/usr/bin/swift test --filter <Suite or Suite/test>`; `task test` runs the
  full suite.
- Gated tests need host features and skip without them: a usable login keychain (tag `.keychain`),
  `/usr/bin/hdiutil` (`.hdiutil`) and macOS 27 for ASIF (`.asif`).
- Fresh gate: `task clean check`.
- Formatting: `task fmt` (swift-format with `.swift-format`, shfmt for `scripts/`).
- Licence headers: a new source file starts with the two SPDX lines; `task lint` runs `reuse lint`.
- Generated files: `Package.resolved` is never edited by hand; regenerate it with
  `/usr/bin/swift package resolve`, only when `Package.swift` changes.
- Not covered: booting a guest (`scripts/dev-env.sh up`, then `run`). It is manual, needs an
  installed VM bundle, and stops the installed container services.
- Host-run defects: record each defect found on the host in the checklist record or the plan Status
  before the branch goes to review.

## Git

- Commits are SSH-signed through the local git config; never bypass signing. The signing key must be
  loaded in `ssh-agent`, because an agent commit cannot answer a passphrase prompt.
- Commit messages: a subject line plus bullet points, essentials only. What changed, never why.
- No AI attribution: no `Co-Authored-By` trailer, no tool footer.
- Agents never push, tag, or create branches or remotes; they propose the exact command. One exception:
  a goal prompt that the human pasted may name a `hex/<slug>` branch, and the session creates it.
- Retro inbox entries (`.agents/retro/inbox/`) are local input for `/hex-retro`; never stage or commit them.

## Documentation and code

Describe current behaviour in the present tense. No history, no migration notes, no rationale
outside `docs/adr/`. When in doubt, cut.

No details about other projects anywhere in this repository — code, docs, ADRs, specs, plans,
commit messages, and the agent files themselves (`AGENTS.md`, `CLAUDE.md`, `.agents/`). The only projects named are the Apple projects this one depends on
(apple/container, apple/containerization, Apple frameworks). Describe what this runtime offers or
needs, not which other tool uses it.

## Conventions

| Artifact | Home | Filename |
|---|---|---|
| ADR | `docs/adr/` | `adr_NNNN_<topic>.md` (MADR) |
| Spec | `docs/specs/` | `spec_<name>.md` |
| Plan | `.agents/plans/` | `plan_<task>.md` |
| Research | `.agents/research/` | `research_<topic>.md` |
| Goal | `.agents/goals/` | written by `/hex-loop` |

Shape follows the documents already in each home; the shipped hex templates are the fallback only.

## Architecture rules

- The package builds against apple/container `804209b1` plus three runtime-plugin commits: tag
  `parbake-804209b1` of the extra-code/container fork, pinned by revision in `Package.swift`.
  `Package.swift` pins containerization 0.53.0, the version the fork pins.
  `container run --runtime container-runtime-macos` needs the CLI built from that revision;
  `scripts/dev-env.sh build` builds it in `.build/dev-env/container` (`CONTAINER_SRC` overrides it).
- Imports: no AppKit outside `Sources/parbake/Setup.swift`; `parbake-agent` imports neither
  `RuntimeMacOS` nor `Virtualization`; `ParbakeVersion` is the shared leaf (ADR 0009).
- `config.toml` sets every `[runtimeConfig]` flag to `false`: no kernel, no init image, no image
  snapshot.
- The plugin keeps its own copies of the runtime XPC helpers instead of making apple/container's
  public.
- A macOS guest cannot start VMs: nested virtualization exists only for Linux guests. Linux
  services a macOS job needs run on the host.
- At most two macOS guests run per host (Virtualization.framework limit).

Security-sensitive paths:

- `container-runtime-macos.entitlements`, `Taskfile.yml` — code signing with
  `com.apple.security.virtualization`.
- `Sources/container-runtime-macos/**` — XPC routes; the plugin runs in the user's launchd domain.
- `Sources/RuntimeMacOS/**` — VZ device configuration, bundle cloning, guest access.
- `scripts/**` — `dev-env.sh` stops and restarts the installed container services.
- `Sources/parbake/**` — the image tool; `parbake create` downloads restore images (`--restore-image`) and builds bundles (`--replace`).

## Scratch

Build output goes to `.build/`, and `dev-env.sh` clones and builds the pinned apple/container fork in
`.build/dev-env/container`. `parbake create` (also with `--restore-image` or `--replace`) writes the restore-image cache to
`~/Library/Caches/parbake` and the default bundle to `~/VM.bundle`, or both under `$PARBAKE_HOME`;
`dev-env.sh` keeps the data of the development container services in `~/.container-macos-dev`. `HOME` is not redirected.

<!-- hex:start -->
Swarm memory: `.agents/memory/hex.md` (search upward; pointers + preferences).
Commands: `/hex-init`, `/hex-discuss`, `/hex-loop`, `/hex-plan`, `/hex-execute`, `/hex-review`, `/hex-architect`, `/hex-finalize`.
<!-- hex:end -->
