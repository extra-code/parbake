<!-- doc_type: explanation -->
# ADR: The release tag is the version source for every shipped binary

## Metadata

**Status:** Accepted
**Date:** 2026-10-22
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** release, versioning
**Supersedes:** N/A
**Superseded By:** N/A
**Amends:** [ADR 0009](adr_0009_module_boundaries_and_one_version_target.md), release-version source only
**Related:** [ADR 0009](adr_0009_module_boundaries_and_one_version_target.md),
[ADR 0013](adr_0013_tagged_releases_and_git_cliff.md)

## Context

`ParbakeVersion` is the shared leaf target for `parbake`, `container-runtime-macos` and
`parbake-agent`. Its current `Parbake.release` constant is a manually maintained `"0.1.0"`.
The binaries report it through their version output or the guest agent's version line. A
release-number change therefore requires a source edit and can drift from the Git tag that names
the release.

A release build must leave the checked-out source unchanged. The package's dependencies, the patched
apple/container fork included, resolve to the revisions that `Package.resolved` pins.

## Decision Drivers

- One human-selected tag supplies the version used by every released binary.
- The release build does not write a version into the tagged commit or the caller's working tree.
- An untagged checkout and a source archive without this repository's Git history report a
  development sentinel.
- The running binaries never inspect Git or the environment to determine their release version.
- The guest-agent protocol number stays independent from the release number.
- The release path validates the tag before using it in source or build commands.

## Considered Options

### Option 1: Keep a checked-in release constant and compare it with the tag

| Pros | Cons |
|------|------|
| Simple SwiftPM build with no stamping step | The tag and source constant duplicate the version |
| A source archive reports the checked-in value | A mismatch can block a release, but still requires a manual version edit |

### Option 2: Derive the version from Git at build or runtime

| Pros | Cons |
|------|------|
| No explicit version input | A source archive has no Git history to resolve |
| A local checkout can inspect its tags | Runtime version output depends on Git metadata or build environment |

### Option 3: Pass the tag version explicitly and stamp a temporary worktree (chosen)

| Pros | Cons |
|------|------|
| The tag is the sole release-version source | The release job creates and cleans a temporary worktree |
| The committed tree and tag remain unchanged | The stamp and every release consumer need a verification gate |
| The worktree resolves the same `Package.resolved` pins as the checkout | Release builds take an additional build step |
| No Git lookup is needed by the resulting binaries | |

| Criterion (weight) | Option 1 | Option 2 | Option 3 |
|--------------------|----------|----------|----------|
| One authoritative release value (3) | 1 | 3 | 3 |
| Builds without Git metadata (2) | 3 | 1 | 3 |
| Leaves tracked source unchanged (3) | 3 | 3 | 3 |
| Version is available at runtime (2) | 3 | 1 | 3 |
| **Weighted total** | **24** | **22** | **30** |

## Decision Outcome

**Option 3.** A `vX.Y.Z` tag is the only source of an official release version. The
release workflow validates the tag, strips the leading `v`, and passes the resulting `X.Y.Z` value
explicitly to the build. The workflow builds from a temporary detached worktree at the tagged commit
and replaces the single `Parbake.release` stamp in that worktree. It does not modify the release
tag's committed tree or the primary checkout.

The temporary worktree is a sibling of the primary checkout and resolves the same `Package.resolved`
pins, the patched apple/container fork included. The workflow removes only the
worktree it created after the build and verification finish.

The committed `Parbake.release` value is the development sentinel `0.0.0-dev`, with one
`// STAMP:release` marker. A normal local build, untagged CI build and source archive without this
repository's Git history report that sentinel. They do not attempt to infer a release from Git.
`ParbakeVersion` continues to own the protocol number and environment-variable name; only the
release string is stamped.

The accepted release tag shape is `vMAJOR.MINOR.PATCH`, with no prerelease suffix or build metadata.
CI rejects malformed versions and tags whose commit is not reachable from `main` before stamping
or building. Version parsing and output stay in `ParbakeVersion`; CI is responsible for validating
the tag and providing the explicit build input.

### Artifact contract

- `parbake --version` and `container-runtime-macos --version` report the same tag version.
- The agent's version line is `<protocol> <release>`, for example `1 1.2.3`.
- The `Agent` file written into a bundle records the line returned by the built guest agent.
- A protocol mismatch continues to fail readiness. A release mismatch remains a warning, not a
  startup failure.
- The version reported by each binary is compiled into that binary; no runtime Git or environment
  lookup is used.

### Release build contract

1. Validate the tag against the release grammar and require the tagged commit to be on `main`.
2. Create a detached worktree at the exact tagged commit beside the primary checkout.
3. Replace exactly one `// STAMP:release` value in `Sources/ParbakeVersion/ParbakeVersion.swift`.
   Fail if the marker is missing, duplicated, or no longer contains the development sentinel.
4. Run the release build, signing and tests from that worktree using the project's required gate.
5. Verify the two CLI version outputs and the guest-agent version line against the stripped tag.
6. Remove the temporary worktree on success or failure; leave the primary checkout unchanged.

Release workflow triggers, release-note generation and the human release process are defined in
[ADR 0013](adr_0013_tagged_releases_and_git_cliff.md).

## Rationale

A version constant committed alongside the tag is a second source of truth. A CI comparison catches
disagreement only after someone has to update both. Resolving a tag with `git describe` avoids that
edit but makes a version depend on repository metadata that a source archive does not carry.

Passing the release value explicitly from the tag preserves a self-contained runtime version while
making the tag authoritative. A temporary sibling worktree keeps the version mutation out of the
release commit and resolves the same pinned dependencies. The version stamping is an
explicit build operation, not a SwiftPM plugin or a runtime Git query.

## Consequences

**Positive:**

- One tag determines the version reported by every release binary and written into the agent line.
- A mismatch between tag and artifact is caught before release.
- Ordinary builds and source archives do not need Git metadata.
- The primary working tree remains unchanged by release stamping.

**Negative:**

- Release CI must create, validate, build and remove a temporary worktree.
- The release worktree resolves and builds every dependency again, the apple/container fork included.
- A local build reports the development sentinel unless the release workflow supplies a tag.
- CI signs ad hoc. A team identity is local only and signs `parbake` alone, because a team-signed plugin cannot start vmnet DHCP (status 1001), see [ADR 0010](adr_0010_keychain_access_follows_the_signing_identity.md).

## NFR coverage

- **Security:** the tag is validated before substitution; the stamp is limited to one marked source
  line; the tagged commit must be reachable from `main`.
- **Operability:** CI verifies the version exposed by both CLIs and the agent line before publishing
  release assets.
- **Cost:** release stamping adds a worktree and a release build, but no runtime dependency.

## Implementation

- [ ] Change the committed `Parbake.release` to the development sentinel and add the unique stamp
  marker.
- [ ] Add a release build task that accepts an explicit version and uses a temporary sibling
  worktree at the tag.
- [ ] Validate the tag grammar and `main` ancestry before creating release artifacts.
- [ ] Verify CLI output, the agent version line and the bundle's `Agent` file against the tag.
- [ ] Ensure cleanup removes only the temporary worktree created by that invocation.
- [ ] Keep ordinary builds and source archives on the development sentinel.

## Validation

- [ ] An untagged build prints `0.0.0-dev` from both CLIs and reports `1 0.0.0-dev` from the agent.
- [ ] A `v1.2.3` release build reports `1.2.3` from both CLIs and `1 1.2.3` from the agent.
- [ ] A malformed tag, duplicate/missing stamp marker, or tag outside `main` fails before artifact
  creation.
- [ ] A release build leaves the primary checkout unchanged.
- [ ] A temporary worktree resolves the same apple/container fork revision as the primary
  checkout.
- [ ] A source archive with its documented dependencies builds and reports the development
  sentinel without this repository's Git history.

## Links

- [ADR 0009](adr_0009_module_boundaries_and_one_version_target.md), module boundaries and agent
  version-line contract
- [ADR 0013](adr_0013_tagged_releases_and_git_cliff.md), release workflow and generated notes
- [spec_guest_agent.md](../specs/spec_guest_agent.md), C-005 and C-006

## Changelog

- 2026-10-22 — Initial version.
