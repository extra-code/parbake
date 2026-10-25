# Research: Release-readiness bar for macOS virtualization tooling

## Metadata

**Date:** 2026-10-22
**Domain:** ci-cd
**Triggered by:** `.agents/discussions/release-audit.md` — entry prior-art lane
**Expires:** 2027-04-22

This is evidence only, with no recommendation. Anka, Orchard and the primary text of the EU Cyber Resilience Act (CRA) were not verified.

## Direct Answer

- None of the comparable projects applies one uniform release bar.
- **Where they are strict:** build and lint hygiene, unit tests and CI discipline. The larger projects are also strict about release signing.
- **Where everyone is weak:** booting a real VM end to end (E2E) in hosted CI.
  - GitHub-hosted Apple-silicon runners cannot run Virtualization.framework guests.
  - apple/container and Tart use self-hosted Apple-silicon machines instead. Lima runs its VM tests on Intel hosted runners.
- First releases (0.1.0) of Tart, Lima, UTM and apple/container shipped with little of their later hardening.
- OpenSSF Best Practices, Scorecard and SLSA check process hygiene, not VM behaviour.

## Key Findings

### Real-VM E2E in CI

- **GitHub-hosted runners:** nested virtualization is "not officially supported" ([docs](https://docs.github.com/en/actions/using-github-hosted-runners/using-github-hosted-runners/about-github-hosted-runners)). A community thread reports that Virtualization.framework cannot start VMs on the arm64 runners ([runner-images#9254](https://github.com/actions/runner-images/issues/9254)).
- **Tart:**
  - GitHub Actions runs `swift build`, `swift test` and a Go integration suite.
  - The Python suite that boots VMs is skipped there because "hosted ARM macOS runners do not support nested virtualization" ([ci.yml](https://github.com/cirruslabs/tart/blob/main/.github/workflows/ci.yml)).
  - The VM tests run on a self-hosted machine, `dev-mini` ([.cirrus.yml](https://raw.githubusercontent.com/cirruslabs/tart/main/.cirrus.yml)).
- **Lima:**
  - It boots real VMs with its vz, QEMU and VMNet drivers on `macos-15-large`, which is an Intel runner ([test.yml](https://raw.githubusercontent.com/lima-vm/lima/master/.github/workflows/test.yml)).
  - That setup does not exercise Virtualization.framework behaviour on Apple silicon.
  - Lima also runs CodeQL and Scorecard.
- **apple/container:**
  - CI runs on `[self-hosted, macos, tahoe, ARM64]`: fmt with a license-header check, `make test install-kernel integration`, and coverage ([common.yml](https://github.com/apple/container/blob/main/.github/workflows/common.yml)).
  - A `verify-signatures` job fails if a pull request contains an unsigned commit ([pr-build.yml](https://raw.githubusercontent.com/apple/container/main/.github/workflows/pr-build.yml)).
- **UTM:** only build and issue workflows, with no tests and no lint.

### Credentials and SSH

- Tart's images use `admin`/`admin`. Its sshpass examples disable host-key checking ([quick-start](https://tart.run/quick-start/)).
- Kubernetes Image Builder shipped default credentials in its build VMs, which led to CVE-2024-9594 ([The Register](https://www.theregister.com/2024/10/16/critical_kubernetes_image_builder_bug/)).

### Signing

- **Tart:**
  - CI builds are signed ad hoc without notarization.
  - Releases are signed and notarized ([release.yml](https://github.com/cirruslabs/tart/blob/main/.github/workflows/release.yml)).
  - Signing fixes still appeared in 2.33.0 and 2.33.1.
- **apple/container 0.1.0:** shipped both a signed and an unsigned pkg ([0.1.0](https://github.com/apple/container/releases/tag/0.1.0)).
- **Lima:** ships SHA256SUMS with a signature (`.asc`), an SBOM and attestation permissions ([release.yml](https://github.com/lima-vm/lima/blob/master/.github/workflows/release.yml)).
- **UTM:** publishes no checksums.

### What the first releases lacked

- **Tart 0.1.0 (2022):** a changelog only.
- **Lima v0.1.0 (2021):** a usage snippet, tarballs and signed SHA256SUMS.
- **UTM v0.1 (2020):** shipped a "fakesign" variant.
- **apple/container 0.1.0 (2025):** "initial release" plus a dSYM.
- **Neither Tart nor apple/container** has a SECURITY.md at the repo root.
- **Scorecard today:**

| Project | Overall | Notable checks |
|---|---|---|
| Lima | 8.7 | Signed-Releases 8, CII-Best-Practices 5 |
| UTM | 3.5 | Token-Permissions 0, Signed-Releases 0, SAST 0 |

### Frameworks

- **OpenSSF Best Practices, passing level, MUST items** ([criteria](https://www.bestpractices.dev/en/criteria/0)):
  - a FLOSS license and documentation;
  - unique version IDs and release notes;
  - a documented bug process;
  - a vulnerability reporting process with a 14-day response;
  - a working build and an automated test suite;
  - a written policy to add tests for new features;
  - a linter, and static analysis before major releases;
  - no private credentials in the repository;
  - no known vulnerabilities older than 60 days;
  - MITM-resistant delivery.
- **What passing level only suggests or does not require:** coverage and CI are only SUGGESTED. Signed releases and an SBOM are not required.
- **Scorecard checks** ([checks.md](https://github.com/ossf/scorecard/blob/main/docs/checks.md)):
  - Critical: Dangerous-Workflow and Webhooks.
  - High: Binary-Artifacts, Branch-Protection, Code-Review, Dependency-Update-Tool, Maintained, Signed-Releases, Token-Permissions and Vulnerabilities.
- **SLSA v1.0 build levels:**
  - L1: provenance exists.
  - L2: provenance is signed by a hosted build platform.
  - L3: the build is hardened.
- **CRA** (secondary sources only):
  - Purely non-commercial open source is out of scope. Stewards have light duties under Art. 24.
  - Parts apply from 9/2026; the full regime from 12/2027 ([OpenSSF](https://policy.openssf.org/CRA/stewards-one-pager.html)).

## negative

- Anka is closed source, and no evidence was found for it. Orchard was not researched.
- Whether Tart's limit on nested virtualization also applies to macOS guests was not verified.
- The release workflows of apple/container and containerization were not read.

## leads

- **Self-hosted Apple-silicon E2E:** look at the runner setups of apple/container and Tart.
- **Scorecard baseline:** run Scorecard against Parbake itself.
- **Notarization and entitlements:** Tart's `sign-release.sh`.
- **CRA legal read:** needed if CI-executor use is monetized.
