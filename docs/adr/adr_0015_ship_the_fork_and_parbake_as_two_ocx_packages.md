<!-- doc_type: explanation -->
# ADR: Ship the fork's container build and Parbake as two OCX packages

## Metadata

**Status:** Accepted
**Date:** 2026-10-28
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** release, distribution, signing, ci

**Supersedes:** N/A
**Superseded By:** N/A
**Amends:** [ADR 0013](adr_0013_tagged_releases_and_git_cliff.md), in two clauses: a tag run
publishes nothing, and no distribution channel is chosen. A tag run still creates no GitHub
Release, and the workflow's top-level `contents: read` stays.
**Related:** [ADR 0012](adr_0012_release_tag_is_the_version_source.md),
[ADR 0010](adr_0010_keychain_access_follows_the_signing_identity.md),
[ADR 0004](adr_0004_keychain_through_the_security_tool.md),
[ADR 0006](adr_0006_guest_agent_speaks_the_sandbox_context_protocol.md),
[ADR 0002](adr_0002_guest_joins_the_container_network.md)

## Context

Parbake runs only under a `container` built from the extra-code/container fork. The fork carries
four patches on top of apple/container. Trying Parbake today means cloning the fork, building it,
building Parbake, installing the plugin into the fork's install root and signing everything ad hoc.
`scripts/dev-env.sh` automates this for contributors, not for users.

[ADR 0013](adr_0013_tagged_releases_and_git_cliff.md) makes a `vX.Y.Z` tag build reviewable
artifacts and publish nothing. It defers publication until a distribution ADR defines it. This ADR
is that record.

Two goals shape it. The fork is temporary, because an Apple release replaces it once
apple/container ships the patches. Parbake is durable and should outlive the fork unchanged.
A third goal is to make OCX visible to the apple/container project. Both packages therefore go into
the [ocx.sh package index](https://ocx.sh/catalog/), with Apple credited as upstream.

### Facts from the fork

- The apiserver's launchd label and Mach service are both `com.apple.container.apiserver`
  (`Sources/ContainerCommands/System/SystemStart.swift:116,121` in the fork). Upstream
  apple/container#1757 records that a second `system start` reports success against the daemon
  that already runs. One apiserver runs per user session, stock or fork.
- The apiserver loads plugins from two directories, both under its install root:
  `<root>/libexec/container/plugins` and `<root>/libexec/container-plugins`
  (`Sources/APIServer/APIServer+Start.swift:186-203`). The second is symlink-resolved, and a plugin
  entry may be a symlink to a directory (`Sources/ContainerPlugin/PluginLoader.swift`).
- `system start --install-root` sets the install root and passes it to every service it launches as
  `CONTAINER_INSTALL_ROOT` (`SystemStart.swift:40-44,111`).
- The fork's binaries need only `com.apple.security.virtualization`, which is not restricted.

### Facts from OCX 0.6.5

- `ocx package install --link <path>` keeps one stable link to the installed package. Re-running it
  with a newer tag moves the link, and the linked package is safe from `ocx clean`. The link points
  at the package directory, and the files sit under its `content/`.
- `ocx package create` refuses a symlink that leaves the package root. A package cannot link itself
  into `/usr/local` or into another package.
- OCX documents no post-install hook.
- `ocx package announce --ephemeral` marks tags as removable without index review. Paired with
  `ocx package push --no-keep-tag`, a later prune frees the storage too.
- A version tag follows `{major}[.{minor}[.{patch}[-{prerelease}][_{build}]]]`. A rolling `1.6.1`
  follows the highest build of 1.6.1. Build parts compare as text, so `_10` sorts below `_9`
  (`crates/ocx_package/src/version.rs` in ocx-sh/ocx).
- `ocx package claim` opens a pull request against `ocx-sh/index`, which a human reviews. Its
  `--upstream-org` fields mark a package that repackages someone else's software. `announce` fails
  until the claim is merged.

### Facts from the spikes

[`research_two_package_spikes.md`](../../.agents/research/research_two_package_spikes.md) records
three attended runs on a macOS 27 host. A root of symlinks carried both packages. The signing results
are:

| Services | Plugin | Result |
|---|---|---|
| ad hoc | ad hoc | the guest boots, gets a DHCP address and answers `exec` |
| team-signed | ad hoc | status 1001 when the guest attaches to the network |
| team-signed | the same team | the guest boots, gets a DHCP address and answers `exec` |
| ad hoc | team-signed | status 1001 (recorded earlier in `docs/signing.md`) |

The plugin loads and starts in every case. Only joining the network of `container-network-vmnet`
fails, and only when the signatures differ.

## Decision Drivers

- A user reaches a running macOS guest in a few commands, with no source build.
- The fork package can be retired without touching Parbake.
- Parbake's install steps stay the same when the fork gives way to an Apple release.
- No build code runs with registry write rights, and no signing secret exists.
- A user can check where each package came from before running it.
- The fork's diff against apple/container does not grow.
- Both packages are listed in the ocx.sh index, with Apple named as upstream of the fork.

## Considered Options

### Option A: One OCX package holding the fork and Parbake

| Pros | Cons |
|------|------|
| One digest holds the fork build and the plugin it was built against | Retiring the fork means re-cutting Parbake's package |
| `ocx package exec` makes the package's `content/` the install root | Every Parbake release rebuilds and republishes the fork |
| No root of symlinks to create | The fork cannot be marked ephemeral apart from Parbake |
| | Apple's project never sees `container` as its own package in the index |

### Option B: Two packages joined by a root of symlinks (chosen)

| Pros | Cons |
|------|------|
| The fork package is ephemeral and retires on its own | The user creates a root of three symlinks once |
| Parbake's package is the same against the fork and a later Apple release | Two tags must match, so the release checks the pairing |
| No fork patch: `--install-root` exists upstream | Every `container` command goes through the root's `bin/container` |
| A Parbake release does not rebuild the fork | |

### Option C: Two packages, with a fork patch for an extra plugin directory

| Pros | Cons |
|------|------|
| No root of symlinks: an environment variable or flag names the plugin directory | The fork's diff grows by a patch Apple may not take |
| Upstreamable as a general feature | Until Apple ships it, a stock `container` cannot use it |
| | The patch must cover both the CLI and `system start` |

### Option D: A GitHub Release with tarballs and checksums

| Pros | Cons |
|------|------|
| Needs no tool beyond `curl` and `tar` | A browser download sets the quarantine attribute on every binary |
| Familiar to most users | Provenance needs a separate attestation beside the checksums |
| | The user picks an install root and maintains it by hand |
| | Publishing needs `contents: write` and adds nothing to the ocx.sh index |

| Criterion (weight) | A | B | C | D |
|--------------------|---|---|---|---|
| Fork retires without re-cutting Parbake's package (3) | 1 | 3 | 3 | 2 |
| Few user steps to a running guest (3) | 3 | 2 | 3 | 1 |
| Fork diff unchanged (2) | 3 | 3 | 1 | 3 |
| Provenance a user can check (2) | 3 | 3 | 3 | 2 |
| OCX visibility in the index (2) | 2 | 3 | 3 | 1 |
| Maintenance beyond the release workflows (1) | 3 | 2 | 1 | 2 |
| **Weighted total** | **31** | **35** | **33** | **23** |

OCX visibility is a criterion because the owner set it as a goal, not because it measures the
design. Isolation from a stock install is not a criterion. The fixed launchd label makes every
option exclusive.

The first criterion scores packaging only. The signing result in § Signing and the later Apple
release hits every option equally. However it is packaged, an ad-hoc plugin cannot join an
Apple-signed network service.

Two variants of B were rejected in prose:

- **B with an OCX dependency** from Parbake on the container package. A dependency pins a digest
  and places no files, so it neither builds the root nor survives a later stock `container`.
- **B with a `parbake` command that creates the root.** It would save the three `ln -s` lines and
  check them. The discussion chose a docs-only path for 0.1.0, so the quickstart checks the root
  instead. The command stays a candidate for a later release.

## Decision Outcome

**Option B.** Two packages, both `darwin/arm64`, both signed ad hoc:

| Package | Physical location | Tags | Lifetime | Built by |
|---|---|---|---|---|
| `ocx.sh/extra-code/container` | `ghcr.io/extra-code/container` | `1.6.1_01`, `1.6.1_02`, … | ephemeral | `ocx-package.yml` in extra-code/container |
| `ocx.sh/extra-code/parbake` | `ghcr.io/extra-code/parbake` | `X.Y.Z` | durable | `release.yml` in extra-code/parbake |

A container tag is the upstream version plus a two-digit build counter after `_`. The counter
starts at `01` and resets when the upstream version changes. Two digits keep the text order right. The rolling `1.6.1`, `1.6` and `1` follow the
highest build.

### The container package

The content is the fork's install root as its Makefile installs it:

```text
bin/container
bin/container-apiserver
libexec/container/plugins/<built-in>/{bin/<name>,config.toml,resources/...}
```

`bin/update-container.sh` and `bin/uninstall-container.sh` are removed. Both act on `/usr/local`
with `sudo`, and the uninstaller deletes the stock install and its data
(`scripts/uninstall-container.sh:18,71,87` in the fork). The metadata puts `${installPath}/bin` on
`PATH` and declares `container` and `container-apiserver` as binaries.

The build runs two make calls and starts no service:

```bash
make BUILD_CONFIGURATION=release build
make BUILD_CONFIGURATION=release DEST_DIR="$ROOT/" SUDO= install
```

`install` with an empty `SUDO` builds `installer-pkg` and unpacks its payload into `DEST_DIR`. It
never runs `init-block` (`Makefile:76-78,111-135,175-189`). `installer-pkg` signs the tree ad hoc
with `com.apple.container.*` identifiers and the entitlements from `signing/`. A leftover
`bin/release/staging/` is removed first, because `make` would treat it as up to date.

The workflow lives on the fork's branch `ocx-package`, one commit on top of `parbake`. The tag
`ocx-1.6.1_NN` points at that commit. Its file `ocx/source-revision` names the 40-hex fork revision
to build. The workflow checks that revision out before `make`, so the binaries match the revision
Parbake pins.

The signing identity binds the workflow and the tag, not the source. The build therefore refuses a
revision that is not an ancestor of `origin/parbake`, and a ruleset protects the branch
`ocx-package` and the `ocx-*` tags. The push records the revision as the annotation
`org.extra-code.container.source-revision`. Apple's own workflows trigger on `main`, pull requests and `X.Y.Z` tags, so neither
the branch nor an `ocx-*` tag starts them.

### The Parbake package

The content is the plugin directory:

```text
bin/container-runtime-macos
bin/parbake
bin/parbake-agent
config.toml
```

The binaries come from `.build/release-assets/X.Y.Z/`, stamped and signed by `scripts/release.sh`.
`config.toml` comes from the release commit. The metadata puts `${installPath}/bin` on `PATH` and
declares the three binaries.

The package declares no OCX dependency on the container package. A dependency pins a digest, places
no files and would be wrong once a stock `container` serves the plugin.
`packaging/container.tag` names the container tag a release is built and tested against. The release
job checks that `ocx/source-revision` at the fork tag `ocx-<tag>` equals the fork revision in
`Package.resolved`. The push records the tag as the annotation `org.extra-code.parbake.container-tag`,
and `CHANGELOG.md` names it too.

The check reads git, not the registry, so it cannot see a failed or pruned container publish. Once
the fork retires, `packaging/container.tag` is deleted and the check reports that it skipped.
Parbake can then release without the fork.

### Install layout

Everything the user creates lives under `~/.parbake`:

```text
~/.parbake/container      --link of ocx.sh/extra-code/container
~/.parbake/plugin         --link of ocx.sh/extra-code/parbake
~/.parbake/root/bin                      -> ~/.parbake/container/content/bin
~/.parbake/root/libexec/container        -> ~/.parbake/container/content/libexec/container
~/.parbake/root/libexec/container-plugins/container-runtime-macos -> ~/.parbake/plugin/content
~/.parbake/app            the services' app root
```

The symlinks are created once. An upgrade moves only an OCX link.

### Commands

`docs/quickstart.md` carries the full path. Its core:

```bash
CONTAINER_PKG=ocx.sh/extra-code/container:1.6.1_01
PARBAKE_PKG=ocx.sh/extra-code/parbake:0.1.0
ocx package install --link ~/.parbake/container "$CONTAINER_PKG"
ocx package install --link ~/.parbake/plugin "$PARBAKE_PKG"
mkdir -p ~/.parbake/root/libexec/container-plugins
ln -s ~/.parbake/container/content/bin ~/.parbake/root/bin
ln -s ~/.parbake/container/content/libexec/container ~/.parbake/root/libexec/container
ln -s ~/.parbake/plugin/content ~/.parbake/root/libexec/container-plugins/container-runtime-macos
/usr/local/bin/container system stop
~/.parbake/root/bin/container system start --install-root ~/.parbake/root \
  --app-root ~/.parbake/app --disable-kernel-install
```

`--disable-kernel-install` skips the Linux kernel, which macOS guests do not use. The start still
needs the network for the init image. The quickstart then checks that
`~/.parbake/root/libexec/container-plugins/container-runtime-macos/config.toml` exists. A wrong link
would otherwise give a running apiserver without the macOS runtime, because the plugin loader skips a
missing directory silently.

`~/.parbake/root/bin/container` is the one entry point for every later `container` command. The CLI
takes its install root from the unresolved path it was started from. A `container` reached through
`ocx package exec` or the store path would see the store's `content/` as its root and miss the
plugin. `parbake` runs as
`ocx package exec "$PARBAKE_PKG" -- parbake …`. Neither package is installed with `--select`, so the
shell `PATH` never holds the fork's `container`.

The check line `launchctl print gui/$(id -u)/com.apple.container.apiserver | grep program` shows
the container package's store path. launchd records the resolved path, not the path through the
root.

### Upgrade and app root

An upgrade of either package runs in three steps:

1. Stop the services.
2. Run `ocx package install --link` with the new tag.
3. Start the services.

The root of symlinks stays as it is. A package that lost its link is removed by `ocx clean`. The
running services use resolved store paths, so `ocx clean` and removing a link both come after
stopping the services, never before.

One app root serves every release. A container tag with a new upstream version says so in the
CHANGELOG. Before starting it, the user removes its containers and resets `~/.parbake/app`, because
upstream does not keep the services' state compatible across versions (apple/container#551).
`~/.parbake/app` holds container state, images and logs, never the user's bundles.

### Signature check

Each packaging step runs `codesign --verify --strict` on every Mach-O file before
`ocx package create`. Mach-O files are found by `file -b`, and a count of zero fails. Every binary
must be signed ad hoc.

`com.apple.security.virtualization` must be present on `container-runtime-linux`,
`container-network-vmnet`, `container-runtime-macos` and `parbake`, and absent on `parbake-agent`.
No binary carries any other entitlement. No symlink leaves the root, and the archive holds no
absolute or `..` member.

### Release workflows

Both repositories use the same two-job shape:

- **build** holds `contents: read`. It builds, verifies and runs `ocx package create`. It uploads the
  archive and its compiled metadata, and outputs the version, the artifact id and both SHA-256
  values.
- **publish** needs build and runs only for its repository's release tag. It holds only
  `packages: write` and `id-token: write`. It checks out nothing and builds nothing. It downloads by
  artifact id, compares both SHA-256 values and installs OCX 0.6.5 with no project and no cache.
  It then runs:

  ```bash
  ocx package push -p darwin/arm64 -m <compiled metadata> --ci-annotations=github --sign --cascade \
    -i ghcr.io/extra-code/<name>:<tag> <archive>
  ```

  The container package adds `--no-keep-tag`. Credentials reach only the push and verify steps,
  through the `OCX_AUTH_ghcr_io_*` variables. A last step runs `ocx package verify` against the pushed
  tag. It proves a signature exists for this workflow. A user's verify from another host is the
  independent check.

The build job of Parbake's `release.yml` also runs the pairing check above, so a mismatch stops the
run before anything is pushed.

### Index listing

Each package is claimed once, after its first push is public. The claim runs from a `claim` workflow
(`workflow_dispatch`) in each repository. The container claim names Apple as upstream:

```bash
ocx package claim --repository oci://ghcr.io/extra-code/container --fork <owner>/index \
  --upstream-org apple --upstream-repository-url https://github.com/apple/container \
  --upstream-disclaimer "Patched build of apple/container for Parbake. Temporary until upstream ships the patches." \
  extra-code/container
ocx package claim --repository oci://ghcr.io/extra-code/parbake --fork <owner>/index extra-code/parbake
```

After that, each repository's `announce` job runs on `ubuntu-latest`. The push writes the tags it
created with `--tags-file`, and the job announces exactly those:
`ocx package announce --tags-file tags.txt --fork <owner>/index`. It never uses `--tags-from-registry`,
because that turns tags not yet announced into durable rows (OCX snapshot-tracks guide). The container
job adds `--ephemeral` from its first run, because a row keeps the marker it was announced with. The job
runs only when the repository variable `OCX_INDEX_ANNOUNCE` is `true`, which the owner sets once the claim
is merged.

The job reads `OCX_ANNOUNCE_TOKEN` from the `release` environment and opens a pull request against
`ocx-sh/index`. The token is preferably a fine-grained personal access token with read access and
pull-request write on `ocx-sh/index` and on the owner's index fork. A classic token with `repo` scope is
the fallback when a fine-grained token cannot be granted those. The environment requires the owner's
approval and admits only release tags.

Container tags are pruned only when no Parbake release in the quickstart pairs with them. When
Apple ships the patches, the container package root is marked `deprecated`, with a message naming
the Apple release to use. Its tags are then removed with `ocx package prune`, which deletes only tags
the index marks ephemeral. `ocx package announce --tags-file` then runs with the pruned tags. Parbake's
package stays.

### Trust policies

Each package gets its own `[[trust.policy]]` with the issuer `https://token.actions.githubusercontent.com`:

- container: `^https://github.com/extra-code/container/.github/workflows/ocx-package.yml@refs/tags/ocx-[0-9]+\.[0-9]+\.[0-9]+_[0-9]{2}$`
- Parbake: `^https://github.com/extra-code/parbake/.github/workflows/release.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$`

Tag rulesets in both repositories let only maintainers create these tags. The signature attests
which workflow built a package, not that its content was reviewed or notarised.

The identity is only as strong as the tag rulesets, because a tag's own workflow file runs. The
fork also protects `parbake` and `ocx-package`. A tag that cannot be updated or deleted also
prevents overwriting a published version.

### Signing and the later Apple release

Everything is signed ad hoc, so the fork's services and the plugin share one signing domain. Each
release is a new code identity. Ad-hoc builds create the guest password item with `-A`
([ADR 0004](adr_0004_keychain_through_the_security_tool.md),
[ADR 0010](adr_0010_keychain_access_follows_the_signing_identity.md)).

The spikes show what the later Apple release changes:

| Phase | Services | Plugin | Network |
|---|---|---|---|
| Today, both packages | fork, ad hoc | ad hoc | works |
| After Apple ships the patches | Apple-signed | ad hoc | fails with status 1001 |
| Same, with a matching signature | Apple-signed | Apple-signed | works, but only Apple can sign it |

The end state therefore needs one of three changes, and this ADR picks none yet:

1. Parbake ships its own build of `container-network-vmnet` under another name, signed like the
   plugin. The guest joins a network created with `container network create --plugin`. This is
   untested, and the guest would sit on a separate subnet.
2. apple/container hands the vmnet network to plugins of another signature. That is a request to
   Apple, backed by the table above.
3. Apple ships the plugin itself.

Until then, the ephemeral container package is the supported way to run Parbake.

### Install-path stability

Upstream apple/container PR #1415 warns about an install root whose path changes per release. Such
a path confuses Local Network privacy. launchd records the resolved store path, which changes with every
container tag. This decision accepts that risk. The plugin needs no Local Network approval
([ADR 0002](adr_0002_guest_joins_the_container_network.md)), and the guest agent talks over vsock
([ADR 0006](adr_0006_guest_agent_speaks_the_sandbox_context_protocol.md)).

## Rationale

The fork and Parbake have different lifetimes, so one package would tie a durable release to a
temporary one. The upstream `--install-root` flag and the plugin loader's symlink handling make a
root of symlinks enough, so the split needs no fork patch. The same plugin directory then serves a
later stock `container` through `/usr/local/libexec/container-plugins`, and Parbake's install steps
stay the same.

Splitting build and publish keeps the write token and the OIDC token away from every step that
compiles code. Both packages go into the ocx.sh index, with Apple credited as upstream. That makes
OCX visible to the apple/container project, with no second index to run.

## Consequences

**Positive:**

- A user runs a macOS guest after two installs and three symlinks, with no Xcode build.
- A Parbake release no longer rebuilds the fork.
- The fork package retires by deprecation, and Parbake's package stays as it is.
- Trust policies tie each package to its own release workflow.
- The fork's diff and the plugin code are unchanged.

**Negative:**

- The user creates a root of symlinks once.
- Two tags must match. The release checks the pairing, and the docs name it.
- The keychain item stays readable by every application of the user, as with every ad-hoc build.
- Each container tag changes the resolved install path, so a privacy grant tied to the path starts
  over.
- Making a package public is a one-way step for the owner. Deleting a version later does not
  unpublish a digest someone already pulled.
- Against a later Apple-signed release, the ad-hoc plugin cannot join Apple's network.

## NFR coverage

- **Security:** build jobs hold `contents: read`. Only publish jobs hold `packages: write` and
  `id-token: write`, and they run only the pinned `setup-ocx` and `ocx`. The announce token is a
  fine-grained token where possible and a broad classic token otherwise. It lives only in the `release` environment, behind the owner's approval, and
  the announce job holds no repository permissions. The container package drops the
  fork's `sudo` scripts.
- **Operability:** the `launchctl print` line shows which apiserver runs. Switching is two commands
  each way.
- **Cost:** the fork builds only for a container tag. GHCR hosting is free for public packages.
- **Integrity:** `codesign --verify --strict` runs before archiving and again on the installed tree.

## Implementation

- [ ] In the fork, add `ocx/source-revision`, `scripts/ocx-package.sh` and
  `.github/workflows/ocx-package.yml` on the branch `ocx-package`.
- [ ] In Parbake, reduce `scripts/package.sh` to the plugin package, and add
  `packaging/container.tag` with the pairing check.
- [ ] Rework `release.yml` for the plugin package, the pairing check and the gated announce step.
- [ ] Rewrite `docs/quickstart.md`, `docs/package.md` and `docs/package-troubleshooting.md` for
  two packages and the root of symlinks.
- [ ] Revise `docs/signing.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md` and `AGENTS.md`.
  ADR 0013 gains an "Amended by ADR 0015" line.
- [ ] After the first pushes, make both packages public, claim them and set `OCX_INDEX_ANNOUNCE`.

## Validation

- [ ] `task check` and the docs gate pass on the changed pages and this ADR.
- [ ] A local run builds both archives, assembles the root from the quickstart and boots a guest.
- [ ] After the first publish, on a macOS 27 host with a stock install:
  - both installs succeed, and `xattr -l` shows no `com.apple.quarantine`.
  - `ocx package verify` passes for both, with their own identities.
  - the quickstart runs word for word, and `exec sw_vers` answers.
  - after switching back, `program` shows the stock apiserver and `container ls` works.
- [ ] Both packages resolve through `ocx.sh/extra-code/…` once their index pull requests merge.

## Links

- [ADR 0013](adr_0013_tagged_releases_and_git_cliff.md), the release contract this ADR amends
- [ADR 0012](adr_0012_release_tag_is_the_version_source.md), the stamped release binaries
- [ADR 0010](adr_0010_keychain_access_follows_the_signing_identity.md), keychain access and identity
- [docs/signing.md](../signing.md), the shared signing domain and status 1001
- [ocx.sh package index](https://ocx.sh/catalog/)

## Changelog

- 2026-10-28: initial version.
- 2026-10-28: review fixes: two-digit build counter, scoring totals, source-revision guard,
  pairing after retirement, entry point and root check, announce token and environment.
- 2026-10-28: ruleset reliance stated after the security review.
- 2026-10-28: accepted after the attended host run of both packages.
- 2026-10-28: aligned with the OCX CI recipes (tags file, claim workflow, token scope).
