State: handed-off → loop · Updated: 2026-10-22
Ratified: 2026-10-22 → loop
Confidence: ratified by Christian Semmelmann; research of 2026-10-22 (codebase recon, prior art, council, repo archaeology, field pitfalls)
Participants: Christian Semmelmann; 7 turns; 2026-10-22

# Discussion: Parbake release audit

## Intent

Audit Parbake (`extra-code/parbake`, `main` at `3607458`) before its first release. The user's request is to check it thoroughly, covering:

- features that are coherent and complete against `docs/specs/` and `docs/adr/`;
- thorough tests and review;
- little duplicated code and a sensible architecture;
- sound security for keychain, SSH, signing and XPC input.

The goal loop (`/hex-loop`) does the work unattended, in two stages. The repository is the only source material.

**Why now:**
- The history has just been rewritten as a clean series.
- The repo is about to be published as a private GitHub repo.
- A first release `v0.1.0` is to follow.

**Out of scope:**
- Notarization and Developer ID distribution: the team is a Personal Team, so only Apple Development is available.
- A binary release artifact.
- A self-hosted CI runner with VZ.
- Pinning SSH host keys.
- Checksums for restore images, which Apple does not publish.
- Guest-agent file copy (C-007 in `docs/specs/spec_guest_agent.md`) and the simulator half of V-4.
- Save/restore (step 5 of `.agents/plans/plan_macos_runtime.md`).
- The cache layer for a base on a network volume (ADR 0001).
- Upstreaming the fork's commits to apple/container.
- Publishing or pushing the repo, which stays the user's step.

## Requirements

### Stage 1: release blockers

1. **Full-repo review.**
   - Run `/hex-review max` over the whole tree, as a diff from `audit/empty` to `audit/all`. Those are two local helper branches: an empty root commit, and a commit carrying the tree of `main`.
   - The panel covers spec, quality, security, performance and docs. Root-cause analysis is on. There is no cross-model adversary, because `hex.md` › Preferences names none.
   - Every finding of severity high or above is fixed or recorded in an ADR as a deliberate deviation.
2. **Architecture review.**
   - Run `/hex-architect` on the module boundaries of `Sources/RuntimeMacOS`, `Sources/container-runtime-macos`, `Sources/parbake` and `Sources/parbake-agent`. Two cases need a decision: `parbake` imports `Virtualization` and `AppKit` directly, and the agent protocol version exists only as a string.
   - The result is an ADR, or a documented "stays as it is".
3. **Checks against specs and ADRs.**
   - Every requirement (C-n) in `docs/specs/` is implemented, or explicitly deferred with a reason.
   - The `Status` of `docs/specs/spec_guest_agent.md` matches reality.
   - `create --config` (`Sources/RuntimeMacOS/BundleConfiguration.swift`) is described in a spec or in the README.
4. **Validate the XPC bundle path.**
   - The path from the label `runtime-macos.bundle` (`Sources/container-runtime-macos/RuntimeService.swift:93`) is checked against allowed roots.
   - It is canonicalized first, with symlinks resolved.
   - Unit tests cover the check.
5. **Signing identity and keychain ACL.**
   - `Taskfile.yml` takes `CODESIGN_IDENTITY`. The default stays ad hoc (`-`).
   - With a stable identity, `Sources/RuntimeMacOS/GuestCredentials.swift` creates the keychain item with an access list restricted to Parbake's binaries.
   - Without one, it keeps `-A` and prints a warning.
   - The measurement from ADR 0004 is repeated on this host with the Apple Development identity once that identity is valid.
   - A new ADR records the result and amends or supersedes `docs/adr/adr_0004_keychain_through_the_security_tool.md`.
6. **Document the security posture.**
   - A `SECURITY.md` names:
     - the private reporting path;
     - the trust model: a dedicated CI user, and who can read the guest password;
     - SSH host-key checking being off (`Sources/RuntimeMacOS/GuestShell.swift:37`);
     - restore images without checksums;
     - ad-hoc signing as the default.
   - The README links it.
7. **README boundaries.**
   - The guest agent is marked experimental as long as `docs/specs/spec_guest_agent.md` is not Implemented.
   - Supported host and guest versions are named.
   - The dependency on apple/container `804209b1` plus the three runtime-plugin commits of the extra-code/container fork is stated.
   - A recipe removes stale overlays and state, since `container clean` is unsupported.
8. **Versioning.**
   - One version source replaces the strings in `Sources/parbake/ParbakeTool.swift:8` and `Sources/container-runtime-macos/RuntimeMacOSHelper.swift:8`.
   - The plugin warns when its version differs from the agent version recorded in the bundle (`Agent`).
   - `CHANGELOG.md` gets its first entry for `v0.1.0`.
9. **Failure messages.**
   - The plugin and `parbake` produce a distinct, actionable error for each of: a lock held by another process, a DHCP timeout, an SSH timeout, an agent timeout, the keychain being locked or refusing access, a missing bundle, and VZ error code 6 (VM limit reached, possibly a leaked slot).
   - An `os_log` subsystem makes `log show` usable.
10. **End-to-end run, done by the loop on this host.**
    - It runs `parbake create --keychain` for a fresh bundle, then `scripts/dev-env.sh up` and `run`.
    - Covered in the run:
      - a command over `exec`, including `exec -t`;
      - stop and the readiness timeout;
      - two guests at once, with a third refused;
      - at least five start/shutdown cycles without a leaked VM slot;
      - the only guest on a network restarting while keeping its address;
      - no overlays left over after a stop or a crash.
    - The checklist lives as a document in `docs/`.
    - The run records the date, host and guest macOS versions, and the commit.
    - The user has allowed the loop to stop and restart the installed container services.
11. **Release mechanics.** The tag `v0.1.0` is prepared as a proposed command. The user sets it.

### Stage 2: hardening (starts only once stage 1 is green)

1. **Test targets** for `Sources/container-runtime-macos/` and `Sources/parbake-agent/`:
   - Each XPC route and each agent operation (create, start, wait, kill, delete, resize) gets a test that needs no VM. The seams are cut first, through protocols or by injecting the process and VM layer.
   - Pure logic in `GuestShell`, `GuestDHCPServer` and `MacOSVirtualMachine` (state transitions, argument building) is tested.
2. **`task coverage`.**
   - It runs `swift test --enable-code-coverage` and `llvm-cov report` and reports line coverage per module.
   - It is not a gate and has no target number.
3. **Remove the duplication, on top of the tests from 1.** The list is complete:
   - one process helper for the five `Process()` sites: `GuestShell:80`, `GuestCredentials:103`, `RestoreImages:94`, `Provision:145` and `GuestProcess:438`;
   - one pipe drain in place of `GuestShell.swift:98-105` and `GuestCredentials.swift:117-124`;
   - one shutdown path in place of the five `sudo -n /sbin/shutdown -h now` sites;
   - one `sudo -S` wrapper (`GuestPreparation.swift:56`, `GuestAgentInstallation.swift:65`);
   - one wait-for-guest loop shared by provision, agent, setup and layer;
   - one error type per module, replacing the ad hoc structs.
4. **Force unwraps.** Remove `GuestProcess.swift:223`, `GuestProcess.swift:506` and `DHCPLeases.swift:30`.

## Decisions

- **Two stages.** Stage 2 starts only after stage 1 is green. A refactor never runs ahead of its tests.
  - Reason: unanimous across the council. Refactoring the VM paths without tests adds risk.
- **Security fixes in code:** the XPC bundle path, and the keychain ACL when a stable identity is present.
  - SSH host keys and restore-image checksums are only documented.
  - Reason for the keychain: ADR 0004 measured that, with ad-hoc signing, a narrower ACL prompts after every rebuild. A stable identity is therefore the precondition.
- **Signing identity:** an Apple Development identity (Personal Team), added on 2026-10-22; identifiers omitted.
  - It is invalid on this host today: `security find-identity -v` finds 0 valid identities, probably because the WWDR G3 intermediate certificate is missing.
  - Fixing that is a precondition for requirement 5. It is the user's step.
- **Release:** a source tag only, with no binary artifact, as long as the build needs the apple/container fork.
- **The end-to-end run is done by the loop itself on this host.** It builds the bundle with `parbake create` and is allowed to stop the container services.
- **Stage 2 is measured by a fixed list plus reported coverage, with no percentage target.**

## Threads

- Release bar against the user's request for hardening. Closed: two stages.
- Keychain: first planned as a code fix, then corrected by the measurements in ADR 0004, finally made conditional on a stable identity. Closed.
- Who runs the end-to-end test. Closed: the loop.
- The untracked `container-runtime-macos-proposal.md` in the repo root. Not committed; the user decides what happens to it.

## Research

- `.agents/research/research_release_audit_codebase_recon.md`: codebase inventory covering features against the specs, the test map, duplication, architecture, security surfaces and docs drift.
- `.agents/research/research_release_readiness_bar.md`: how comparable VM tools and apple/container handled their first releases, plus OpenSSF Best Practices, Scorecard, SLSA and the CRA.
- `.agents/research/research_release_audit_council.md`: three blind seats (premortem, operability, simplicity) on which criteria block the release.
- `.agents/research/research_release_audit_archaeology.md`: replaced approaches, open items, churn, recorded validations.
- `.agents/research/research_release_audit_field_pitfalls.md`: field reports on VZ slot leaks, headless keychain access, vmnet and DHCP, shutdown, version skew and disk space.

## Related

- `docs/specs/spec_guest_agent.md`, `docs/specs/spec_bundle_rebuild.md`, `docs/specs/spec_layer_bundles.md`
- `docs/adr/adr_0001_overlay_per_container_on_an_asif_base.md` … `docs/adr/adr_0008_what_a_ci_executor_can_rely_on.md`
- `.agents/plans/plan_macos_runtime.md`
- `AGENTS.md` › "Verification", › "Architecture rules", › "Git"
- `scripts/dev-env.sh`, `Taskfile.yml`, `.github/workflows/ci.yml`

## Open questions

- [NEEDS CLARIFICATION: Does save/restore (plan step 5) work under the stable Apple Development signature?]
  Recommended: measure it once, as a side effect of requirement 5, and record the result in the plan. It does not block — it is outside the release scope.
- [NEEDS CLARIFICATION: What if the WWDR G3 certificate is still missing when the loop reaches requirement 5?]
  Recommended: the loop builds the `CODESIGN_IDENTITY` plumbing and the conditional ACL with tests, skips only the measurement on the host, and stops at that point with a note for the user.
- [NEEDS CLARIFICATION: How does the loop deal with the helper branches `audit/empty` and `audit/all` after the review?]
  Recommended: delete them after the stage 1 review. The user explicitly allowed creating them on 2026-10-22.

## Verification

- **Stage 1 is done when all of these hold:**
  - `task clean check` is green;
  - the `/hex-review max` report has no open finding of severity high or above;
  - the ADR on architecture and the ADR on keychain/signing exist;
  - `SECURITY.md`, the README boundaries and `CHANGELOG.md` exist;
  - the end-to-end checklist in `docs/` is filled in by the loop for the release commit, with date, host and guest versions and commit;
  - the tag command is proposed.
- **Stage 2 is done when all of these hold:**
  - test targets exist for the plugin and the agent;
  - `task coverage` reports line coverage per module;
  - every item on the stage 2 list is done or justified in an ADR;
  - `task clean check` is green;
  - after the refactors, the end-to-end checklist passes again on this host;
  - `/hex-review` on the stage 2 branch has no open finding of severity high or above.
- **Commits:** every change lands through `/hex-finalize` as signed commits on a feature branch. The loop does not push and does not merge into `main`; that stays with the user.
