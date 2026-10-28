<!-- doc_type: explanation -->
# ADR: Human-selected release tags and git-cliff release notes

## Metadata

**Status:** Accepted
**Date:** 2026-10-22
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** release, ci
**Supersedes:** N/A
**Superseded By:** N/A
**Amended By:** [ADR 0015](adr_0015_ship_the_fork_and_parbake_as_two_ocx_packages.md)
**Related:** [ADR 0012](adr_0012_release_tag_is_the_version_source.md),
[ADR 0008](adr_0008_what_a_ci_executor_can_rely_on.md)

## Context

The CI workflow in `.github/workflows/ci.yml` runs on pushes to `main` and pull requests. It does
not define a release-tag workflow. `git-cliff` is already pinned in the `release` group in
`ocx.toml`, but the repository has no `cliff.toml` configuration and no task that runs it.
`CHANGELOG.md` is currently maintained in the repository.

[ADR 0012](adr_0012_release_tag_is_the_version_source.md) makes a release tag the source of the
version embedded in release binaries. This ADR defines who chooses that tag, what CI checks, and
how release notes are produced. It does not choose a binary distribution channel.

## Decision Drivers

- A human owns the major, minor or patch decision.
- A tag must not release unreviewed code or a version with an invalid shape.
- The release gate builds and verifies the exact commit identified by the tag.
- Release notes are derived from the range between release tags without writing generated content
  into the tagged source tree.
- The release path uses the pinned `git-cliff` binary through the existing `ocx` toolchain.
- Release automation does not impose a new commit-message format.

## Considered Options

### Option 1: Human-selected protected tags and generated notes (chosen)

| Pros | Cons |
|------|------|
| The maintainer makes the release decision explicitly | A maintainer must choose and push each tag |
| The tag, binaries and notes share one release boundary | CI needs complete tag history for the notes |
| No release commit or automatic version decision | The release workflow and tag rules need setup |
| Works with the existing `git-cliff` pin | The existing `CHANGELOG.md` remains a separate curated surface |

### Option 2: Infer versions from commit messages

| Pros | Cons |
|------|------|
| Can propose the next version automatically | Requires a commit-message convention and enforcement |
| Can couple version selection to note categories | Moves the version decision from the maintainer to parsing rules |

### Option 3: Keep manual tags and hand-written release notes

| Pros | Cons |
|------|------|
| No release-note tooling or workflow change | Reconstructing changes between tags is manual |
| Keeps the current release ceremony | Does not provide a repeatable tag-to-notes gate |

| Criterion (weight) | Option 1 | Option 2 | Option 3 |
|--------------------|----------|----------|----------|
| Human control of version decision (3) | 3 | 1 | 3 |
| No new commit convention (2) | 3 | 1 | 3 |
| Repeatable release notes (3) | 3 | 3 | 1 |
| Fits current pinned tooling (2) | 3 | 1 | 2 |
| **Weighted total** | **30** | **16** | **22** |

## Decision Outcome

**Option 1.** A maintainer selects and pushes a `vMAJOR.MINOR.PATCH` tag for a commit
reachable from `main`. The repository's tag rules restrict creation of `v*` tags to the designated
release maintainers. CI applies the exact release-tag pattern, independently verifies that the tag
commit is reachable from `main`, and runs the tagged build and artifact checks defined in ADR 0012.

The tag-triggered workflow generates release notes with `git-cliff` from the commits since the
previous version tag. It writes `.build/release-assets/changelog.md` and does not commit generated
content or change the tag. The release workflow does not infer a version from commits and does not
require Conventional Commits. It renders commit subjects and their bullet bodies according to the
repository's commit-message convention.

`git-cliff` is invoked through a `release:notes` Task target and the already pinned `ocx` release
group. The tag workflow fetches the full history and tags so the previous version tag and complete
range are available. The generated notes are uploaded as a workflow artifact for maintainer review.

`CHANGELOG.md` remains the curated, tracked project changelog. The generated release notes do not
rewrite it. The release-note artifact and changelog have distinct roles: release notes list the
changes in the tag range; `CHANGELOG.md` remains the maintained summary of notable project changes.

CI produces a reviewable workflow artifact after all checks pass. It does not create a published
GitHub Release, upload binaries to a package registry or choose a long-term binary distribution
channel. That decision is deferred until the distribution format and consumer workflow are defined.

### Release contract

1. Only `vMAJOR.MINOR.PATCH` tags trigger a release workflow. Prerelease suffixes and other tags do
   not trigger release jobs.
2. Tag creation is restricted by the repository's protected-tag rules to release maintainers.
3. The tagged commit must be reachable from `main`; the workflow fails before building if it is not.
4. The workflow validates the version, runs the project's required check, builds and signs the
   release binaries from the tagged commit, and verifies their reported versions.
5. The workflow generates release notes from the previous version tag through the current tag.
6. Release notes and build outputs are reviewable artifacts. No package publication is performed
   until a distribution ADR defines it.

### Release notes contract

- `cliff.toml` uses the `vX.Y.Z` tag shape.
- The notes cover commits since the prior matching release tag and exclude merge commits.
- Commits remain free-form under the repository's subject-and-bullets convention.
- `task release:notes` writes only under `.build/release-assets/`, which is already ignored.
- The CI job fetches all tags and full history; a shallow, current-tag-only checkout is insufficient.
- The task can be run locally against a repository with the relevant tags and produces the same
  output as CI.

## Rationale

The version number is a product release decision, not a reliable consequence of parsing commit
messages. A human-selected tag keeps that decision explicit and supplies the exact version that
ADR 0012 embeds in the binaries. A release gate validates who can create the tag, its shape and the
reviewed commit it points to.

The repository already pins `git-cliff`, so generating notes adds configuration and a task rather
than a new runtime dependency. Keeping the generated output out of the tagged source tree avoids a
release commit or a second version source. `CHANGELOG.md` remains a separate curated summary, while
tag-range notes provide a repeatable record of the commits in each release.

## Consequences

**Positive:**

- The release version is selected once in the tag and consumed by the tagged build.
- A tag outside the release grammar or outside `main` cannot proceed through the release gate.
- Every tagged release has notes generated from the same range definition.
- No commit-message parser decides versions, and no generated release commit is needed.

**Negative:**

- Maintainers must create protected release tags and review the generated notes.
- The release-note job needs full Git history and tags.
- `CHANGELOG.md` and generated release notes are separate surfaces and need clearly distinct
  purposes.
- Binary publication remains undefined until a distribution channel is chosen.
- Protected tag rules assume a GitHub plan that offers them for this repository. Applying them is the maintainer's step.
- CI signs ad hoc. A team identity is local only and signs `parbake` alone, because a team-signed plugin cannot start vmnet DHCP (status 1001), see [ADR 0010](adr_0010_keychain_access_follows_the_signing_identity.md).

## NFR coverage

- **Security:** release tags are restricted to designated maintainers; CI verifies tag ancestry
  before building; release credentials are not exposed to untrusted pull-request runs.
- **Operability:** the tag, validation, build gate and generated notes provide a repeatable release
  record.
- **Cost:** `git-cliff` is already pinned; the main added cost is full-history checkout and release
  build time.

## Implementation

- [ ] Add `cliff.toml` with the repository tag pattern and subject/body rendering.
- [ ] Add `release:notes` to `Taskfile.yml`, invoking the pinned `git-cliff` through `ocx`.
- [ ] Add a tag-triggered CI workflow with restricted write permissions and the release-tag pattern.
- [ ] Fetch full history and all tags for the release-note job.
- [ ] Enforce protected `v*` tags for designated release maintainers in repository settings.
- [ ] Verify the tag commit is reachable from `main` before the release build.
- [ ] Run `task check`, the ADR 0012 stamped release build and artifact-version checks.
- [ ] Preserve `.build/release-assets/changelog.md` and build outputs as reviewable CI artifacts
  without publishing them to an undefined channel.
- [ ] Document the release-tag procedure and the distinct role of `CHANGELOG.md`.

## Validation

- [ ] A valid `vX.Y.Z` tag on `main` runs the release workflow.
- [ ] A non-version tag, malformed version, or tag outside `main` produces no release artifact.
- [ ] A tag pipeline sees both the current and previous release tags and generates only the
  intervening notes.
- [ ] `task release:notes` works locally with the same pinned `git-cliff` configuration.
- [ ] The release notes do not modify tracked files.
- [ ] Pull-request workflows do not receive release-write credentials.

## Links

- [ADR 0012](adr_0012_release_tag_is_the_version_source.md), tag-derived release version and
  stamped build
- [ADR 0008](adr_0008_what_a_ci_executor_can_rely_on.md), CI execution constraints
- [CHANGELOG.md](../../CHANGELOG.md), curated project changelog

## Changelog

- 2026-10-22 — Initial version.
