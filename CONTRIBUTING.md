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

A maintainer releases by tagging a commit on `main` with `vX.Y.Z`. The workflow
`.github/workflows/release.yml` builds, verifies and signs ad hoc, then uploads the binaries and the
generated notes as a workflow artifact. It publishes nothing.

- `task release:build VERSION=X.Y.Z` builds a release locally. Local and untagged builds report `0.0.0-dev`.
- `task release:notes` writes `.build/release-assets/changelog.md` with git-cliff.
- The generated notes list the commits of one tag range. `CHANGELOG.md` stays the curated summary.

[ADR 0012](docs/adr/adr_0012_release_tag_is_the_version_source.md) and
[ADR 0013](docs/adr/adr_0013_tagged_releases_and_git_cliff.md) define the release.

Contributions are licensed under the [Apache License 2.0](LICENSE).
