# Research: Release-readiness bar for macOS virtualization tooling

## Metadata

**Date:** 2026-10-22
**Domain:** ci-cd
**Triggered by:** `.agents/discussions/release-audit.md` — entry prior-art lane
**Expires:** 2027-04-22

This is evidence only, with no recommendation. Comparable tools are named by role, not by name:
tool A is a Virtualization.framework VM CLI, tool B a Linux VM manager, tool C a VM app. A closed-source CI
virtualizer, an orchestration tool and the primary text of the EU Cyber Resilience Act (CRA) were not verified.

## Direct Answer

- None of the comparable projects applies one uniform release bar.
- **Where they are strict:** build and lint hygiene, unit tests and CI discipline. The larger projects are also strict about release signing.
- **Where everyone is weak:** booting a real VM end to end (E2E) in hosted CI.
  - GitHub-hosted Apple-silicon runners cannot run Virtualization.framework guests.
  - apple/container and tool A use self-hosted Apple-silicon machines instead. Tool B runs its VM tests on Intel hosted runners.
- First releases (0.1.0) of tools A, B and C and of apple/container shipped with little of their later hardening.
- OpenSSF Best Practices, Scorecard and SLSA check process hygiene, not VM behaviour.

## Key Findings

### Real-VM E2E in CI

- **GitHub-hosted runners:** nested virtualization is "not officially supported" ([docs](https://docs.github.com/en/actions/using-github-hosted-runners/using-github-hosted-runners/about-github-hosted-runners)). A community thread reports that Virtualization.framework cannot start VMs on the arm64 runners ([runner-images#9254](https://github.com/actions/runner-images/issues/9254)).
- **Tool A:**
  - GitHub Actions runs `swift build`, `swift test` and a Go integration suite.
  - The suite that boots VMs is skipped there, because hosted ARM macOS runners do not support nested virtualization.
  - The VM tests run on a self-hosted machine.
- **Tool B:**
  - It boots real VMs with its vz, QEMU and VMNet drivers on an Intel hosted runner.
  - That setup does not exercise Virtualization.framework behaviour on Apple silicon.
  - It also runs CodeQL and Scorecard.
- **apple/container:**
  - CI runs on `[self-hosted, macos, tahoe, ARM64]`: fmt with a license-header check, `make test install-kernel integration`, and coverage ([common.yml](https://github.com/apple/container/blob/main/.github/workflows/common.yml)).
  - A `verify-signatures` job fails if a pull request contains an unsigned commit ([pr-build.yml](https://raw.githubusercontent.com/apple/container/main/.github/workflows/pr-build.yml)).
- **Tool C:** only build and issue workflows, with no tests and no lint.

### Credentials and SSH

- Tool A's images use a well-known default account and password. Its SSH examples disable host-key checking.
- A VM image builder for cluster nodes shipped default credentials in its build VMs, which led to a CVE in 2024.

### Signing

- **Tool A:**
  - CI builds are signed ad hoc without notarization.
  - Releases are signed and notarized.
  - Signing fixes still appeared in later minor releases.
- **apple/container 0.1.0:** shipped both a signed and an unsigned pkg ([0.1.0](https://github.com/apple/container/releases/tag/0.1.0)).
- **Tool B:** ships SHA256SUMS with a signature (`.asc`), an SBOM and attestation permissions.
- **Tool C:** publishes no checksums.

### What the first releases lacked

- **Tool A 0.1.0 (2022):** a changelog only.
- **Tool B v0.1.0 (2021):** a usage snippet, tarballs and signed SHA256SUMS.
- **Tool C v0.1 (2020):** shipped a "fakesign" variant.
- **apple/container 0.1.0 (2025):** "initial release" plus a dSYM.
- **Neither tool A nor apple/container** has a SECURITY.md at the repo root.
- **Scorecard today:**

| Project | Overall | Notable checks |
|---|---|---|
| Tool B | 8.7 | Signed-Releases 8, CII-Best-Practices 5 |
| Tool C | 3.5 | Token-Permissions 0, Signed-Releases 0, SAST 0 |

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

- The closed-source CI virtualizer had no public evidence. The orchestration tool was not researched.
- Whether tool A's limit on nested virtualization also applies to macOS guests was not verified.
- The release workflows of apple/container and containerization were not read.

## leads

- **Self-hosted Apple-silicon E2E:** look at the runner setups of apple/container and tool A.
- **Scorecard baseline:** run Scorecard against Parbake itself.
- **Notarization and entitlements:** tool A's release signing script.
- **CRA legal read:** needed if CI-executor use is monetized.
