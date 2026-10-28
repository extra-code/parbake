<!-- doc_type: explanation -->
# Contributing to Parbake

## Set up

Parbake builds against apple/container `804209b1` with three runtime-plugin commits, tag
`parbake-804209b1` of the [extra-code/container](https://github.com/extra-code/container) fork.
`Package.swift` pins that commit by revision and containerization 0.53.0, and SwiftPM fetches both.

```bash
git clone git@github.com:extra-code/parbake.git
cd parbake
ocx pull      # renders the toolchain; the lint tools download on first use
task          # lists the tasks
```

`scripts/dev-env.sh build` clones the same commit into `.build/dev-env/container`, builds the
development container services there and installs the plugin into them. Set `CONTAINER_SRC` to
build from another apple/container checkout instead.

The other requirements are in the [README](README.md#requirements). Builds are signed ad hoc.
[docs/signing.md](docs/signing.md) covers signing with an Apple Development identity.

## Change and verify

| Task | Does |
|---|---|
| `task check` | lint, build, sign and test; run it before every pull request |
| `task fmt` | format Swift with `.swift-format` and shell scripts with shfmt |
| `task test` | run the Swift tests; `/usr/bin/swift test --filter <Suite>` runs one suite |
| `task coverage` | print line coverage per module; it reports and sets no threshold |
| `task install` | install the signed plugin into `INSTALL_ROOT` (default `/usr/local`) |

`task check` does not boot a guest. For a change to the runtime, the guest agent or parbake,
boot one with `scripts/dev-env.sh up` and `scripts/dev-env.sh run <bundle>`.

<!-- REUSE-IgnoreStart -->
Every source file starts with two SPDX comment lines: `SPDX-FileCopyrightText: <year> <name>` and
`SPDX-License-Identifier: Apache-2.0`. A contributor adds their own `SPDX-FileCopyrightText` line.
`REUSE.toml` covers the files that take no comment, and `task lint` checks both with `reuse lint`.
<!-- REUSE-IgnoreEnd -->

## Commits and pull requests

- A commit message is a subject line in the imperative plus bullet points of what changed.
- Decisions go into an ADR in `docs/adr/`. Behaviour is described in the present tense.
- Commits are signed.

## Release

Two repositories release two OCX packages, both `darwin/arm64` and signed ad hoc.

- A fork release is the tag `ocx-<tag>`, for example `ocx-1.6.1_01`, on the branch `ocx-package` of the extra-code/container fork. Set `ocx/source-revision` first. The fork's workflow `ocx-package.yml` builds the container package and publishes it.
- A Parbake release is the tag `vX.Y.Z` on a commit on `main`. The workflow `.github/workflows/release.yml` builds, verifies and signs ad hoc, then uploads the binaries, the generated notes and the plugin package as workflow artifacts. The `publish` job pushes the package to `ghcr.io/extra-code/parbake` and signs it.
- `packaging/container.tag` names the container tag a Parbake release pairs with. The release job checks that `ocx/source-revision` at the fork tag `ocx-<tag>` equals the fork revision in `Package.resolved`. A mismatch stops the run before any push. `CHANGELOG.md` names the paired tag.
- `task release:build VERSION=X.Y.Z` builds a release locally. Local and untagged builds report `0.0.0-dev`.
- `task release:notes` writes `.build/release-assets/changelog.md` with git-cliff.
- `task package VERSION=X.Y.Z` builds the plugin package locally as a dry run. Add `RELEASE_ALLOW_NON_MAIN=1` off `main`. Before the fork tag is pushed, set `PACKAGE_PAIR_LOCATION` to a fork clone so the pairing check can read it. The archive lands in `.build/package/`.
- The push links each package to its repository through `org.opencontainers.image.source`. The fork's first publish came out public. If a package is private after its first publish, the owner makes it public once in the GHCR package settings, which cannot be undone. Until then the release job's anonymous signature check fails.
- After the public flip, the owner claims the Parbake package in the ocx.sh index by running the `claim` workflow (Actions, Claim, Run workflow). Then the owner sets `OCX_INDEX_ANNOUNCE` to `true` as a repository variable, because a job-level `if` cannot read environment variables. The `announce` job passes the tags the push wrote through `--tags-file` and opens the index pull request, behind the owner's approval of the `release` environment.
- The announce token is preferably a fine-grained personal access token with read access and pull-request write on `ocx-sh/index` and on the owner's index fork. A classic token with `repo` scope is the fallback when a fine-grained token cannot be granted those.
- Rulesets protect `v*` tags in this repository: maintainers only, no update, no delete. The `release` environment admits only `v*` tags. These rulesets make the signing identity meaningful, because a tag's own workflow file runs. The fork applies the same protection to its `ocx-*` tags.
- A first push that returns 403 means the package needs the repository under "Manage Actions access".
- A container tag that moves to a new upstream version gets a `CHANGELOG.md` line that tells users to reset `~/.parbake/app`.
- The generated notes list the commits of one tag range. `CHANGELOG.md` stays the curated summary.

[ADR 0012](docs/adr/adr_0012_release_tag_is_the_version_source.md) and
[ADR 0013](docs/adr/adr_0013_tagged_releases_and_git_cliff.md) and
[ADR 0015](docs/adr/adr_0015_ship_the_fork_and_parbake_as_two_ocx_packages.md) define the release and the packages.

Contributions are licensed under the [Apache License 2.0](LICENSE).
