# Research: Parbake release audit, stage 1 review

## Metadata

- Date: 2026-10-22. Reviewer: /hex-review (xhigh), unattended goal loop, meta-plan gate pre-approved.
- Target: `main...hex/release-audit`, HEAD `6b14c1de08b1328d0b6856a8bb377dedad32b9d4`.
- Spec: [plan_release_audit_stage1.md](../plans/plan_release_audit_stage1.md) (State `review` on entry).
- Trace source: [research_release_audit_full_review.md](research_release_audit_full_review.md).

## Code Review: main...hex/release-audit

### Summary

- **Verdict: Request Changes.** There are 2 unresolved Block findings, both docs that are wrong about shipped
  behaviour, and one systemic cause (R-A) behind 3 or more findings.
- Tier: xhigh (auto). The diff has 92 files, +5767/-427, and 5 areas: RuntimeMacOS, the plugin, parbake with the
  agent, build and scripts, and docs. That is over 15 files and 500 lines, and the plan's `Tier: xhigh` agrees.
  Classification was confident.
- Baseline: `main` (default). The plan had no `Reviewed:` anchor.
- Overlays: breadth=adversarial, rca=on (above Suggest), adversary=off.
- Cross-model: **skipped: no adversary is pinned in `hex.md`, and no second harness is on `PATH`.** One review layer
  is missing.
- Integration gate: `task clean check` exited 0 at 6b14c1d. That is the gate evidence; reviewers did not re-run the
  suite.
- Architect: no boundary violation. `scripts/lint-boundaries.sh` exits 0 and its self-test passes 16 cases. ADR 0009
  is still `Proposed` although its Implementation list is done, which is the decider's call (deferred).
- SOTA: the researcher confirmed the `--help` root cause in swift-argument-parser 1.8.2. Apple documents no reboot
  callback for VZ macOS guests.
- Counts after max-wins dedup: **Block 2, High 4, Warn 36 (26 actionable, 10 deferred), Suggest 18.** Deferred items are within those counts.

### Run record

| Stage | Seats (all standard class) | Notes |
|---|---|---|
| Stage 1 | 8 spec (CW, P1–P7), 5 test-coverage (CW+P1, P2, P3, P4), 1 seams | P5–P7 have no test surface, so they got no coverage seat. Batches of 8 and then 6, under cap 8 |
| Stage 2 | user-feedback (CLI surface), security, performance, doc-reviewer, architect, researcher | The seams seat overlapped Stage 2 by one worker, with 7 live, under the cap |
| Adversary | none | not pinned |

Decisions recorded for this run:

- **No suite runs by reviewers.** 14 concurrent seats sharing `.build` would contend. The gate evidence covers the
  suite.
- **Read-only binary runs.** The orchestrator and the user-feedback seat ran `parbake --help`,
  `parbake create --help`, `--version` and validation-time errors on the built binaries. Nothing reached a download
  or a VM.
- **Where the `--help` defect came from.** It is named in no tracked file: not the checklist, not Q20–Q24, not the
  retro inbox. It was reproduced locally instead (see host-run defect 5).
- **ADR 0009 Status.** "Set Accepted" stays deferred to the decider. AGENTS.md and the specs keep the approval
  with the human.

### Stage 1 — Correctness

#### Spec compliance (post-Implement traceability)

| Slice | Result | Gaps |
|---|---|---|
| CW | needs work | C-004 has no test |
| P1 | pass | the C-021 `resetOverlay` swap is not atomic, though the doc comment claims it is |
| P2 | pass | C-013: `GuestPreparation.script` trusts its caller for `sudoCommands` |
| P3 | pass | S-005 and S-013 are wrong expectations, not code gaps |
| P4 | needs work | C-012 never emits 66; C-040 reads the stdin password after the install (H-08) |
| P5 | needs work | C-050 has no way to sign `parbake` alone, which the docs advise (Q20) |
| P6 | needs work | the README 66 row and keychain line contradict code; checklist steps 7, 10, 17 and 18 |
| P7 | needs work | C-071 is recorded with 3 failed steps whose expectations are unchanged; ADR 0010 holds PII |
| Seams | needs work | `RuntimeFailure.bundleMissing` is unreachable from parbake; a `ContainerizationError` exits 1 |

#### Test coverage (Specify-phase adequacy)

- The pure functions are well covered: the RuntimeLifecycle signal table, both lost-process messages, unsupported
  inputs, `mapStartError`, RuntimeFailure, Validated, AgentVersionLine, ParbakeExit, GUISession and the
  DHCP mutation suite.
- The plugin's actor glue has no test target, which the plan accepts until stage 2. Untested branches are at
  RuntimeService.swift:94-100, 127-140, 164-167, 197-201, 217-227, 317-336, 374-378 and 548-559, and
  MacOSVirtualMachine.swift:174-179 (lock-held after the deadline). OSLogHandler is untested.
- Weak assertions: BundlePathPolicyTests and ProvisionInputsTests check `throws: (any Error)` or
  `BundlePathError.self` and never the case.

### Stage 2 — Adversarial panel

#### Quality / user-feedback

- Observed: `parbake --help` and `parbake create --help` exit 0 but write the help to **stderr** prefixed `Error:`.
  `parbake --version` writes to stdout. `container-runtime-macos --help` is normal. `create --username Bad` exits
  64 with a clear rule and the generic usage banner.

#### Security

No Block and no High. The findings by location and class are in the table below: CWE-117/532, CWE-732, CWE-359,
CWE-367/59, CWE-78/74 hardening, and CWE-269 wording. No secrets are in the diff. No dependency changed. The
entitlements are right: the plugin and `parbake` carry virtualization, and `parbake-agent` carries none.

#### Performance

No Block and no High. The detached SSH shutdown holds a cooperative-pool thread for up to 60 s and cannot be
cancelled. The rest are cold-path polls.

#### Documentation

The doc-declaration check exits 0 with 15 DOC-TYPE-01 hits. The changed files among them are ADR 0004 and ADR 0009;
AGENTS.md is agent config and is skipped. Prose: 8 warnings. The accuracy items are in the table below.

#### Architecture

ADR 0010 and ADR 0011 are honoured in code. ADR 0008 is contradicted by its 66 row. ADR 0002 makes no promise about
the address, but the checklist expects one. ADR 0003 sits uneasily with the stop-path cap of `min(timeout, 60 s)`.
ADR 0009's text is stale in two places: the lint lives in a script, and `RuntimeMacOS` uses a plain
`import ParbakeVersion` where the ADR says `public import`.

#### SOTA / technical soundness

See the host-run grading below. The researcher's sources:
- <https://developer.apple.com/forums/thread/782007>: VZ restore error 12 follows a MAC change or a locked keychain.
  It is about 17 months old.
- <https://developer.apple.com/forums/thread/848707>: a guest reboot shows as device resets.
- <https://developer.apple.com/documentation/virtualization/vzvirtualmachinedelegate>

### Findings (max-wins, one line each)

Class: **A** actionable, **D** deferred (needs a human decision).

| ID | Sev | Class | Location | Issue | Remediation |
|---|---|---|---|---|---|
| F-01 | Block | A | README.md:289; docs/adr/adr_0008_what_a_ci_executor_can_rely_on.md:110; CHANGELOG.md:12; Sources/RuntimeMacOS/MacOSVMBundle.swift:54,59; Sources/parbake/ParbakeExit.swift:27; Sources/parbake/Create.swift:174-177; Install.swift:30 | Exit 66 is documented and never emitted. A missing bundle throws `ContainerizationError(.notFound)`, which exits 1. A missing restore-image path is not checked and fails later with exit 1. `bundleMissing` is thrown only in the plugin | Throw `RuntimeFailure.bundleMissing` from `MacOSVMBundle.init(url:)`, or map `.notFound` in `ParbakeExit`. Check a `.file` restore image before the lock. Add test rows. Otherwise reword all three docs (R1.2, R2.1) |
| F-02 | Block | A | README.md:118-120 | The README says every keychain access goes through `/usr/bin/security` with `-A`. That holds for ad-hoc builds only; a team build uses in-process `creatorOnly` (ADR 0010). It contradicts SECURITY.md and CHANGELOG | State the ad-hoc case and link SECURITY.md's keychain section (R2.1) |
| F-03 | High | A | Sources/parbake/ParbakeTool.swift:40-45 | `--help` goes to stderr as `Error: OVERVIEW…` with rc 0 and is logged at os_log error. `parseAsRoot` returns a `HelpCommand` whose `run()` throws `CommandError`, so the guard misses it | `if ParbakeTool.exitCode(for: error) == .success { exit(withError: error) }` before the custom path. Test the streams (R1.1) |
| F-04 | High | A | Sources/parbake/Provision.swift:79; Sources/parbake/AgentSetup.swift:62-69 | H-08 is still open: without `--keychain` and with no TTY, the stdin password is read after the multi-GB install, and a failure deletes the bundle | Read or require it in `Create.validateAccount` before the download (R1.3) |
| F-05 | High | A | Taskfile.yml:57-59; docs/signing.md:66-70; scripts/dev-env.sh:36-37 | The docs say to team-sign `parbake` and keep the plugin ad hoc. One `CODESIGN_IDENTITY` signs all three binaries, so following the docs gives either vmnet status 1001 or a `-A` keychain item | Add `PARBAKE_CODESIGN_IDENTITY` for `parbake` alone, or document the manual re-sign (R1.7) |
| F-06 | High | A | Sources/parbake/ParbakeExit.swift:19-27 | Exit codes have no harness test: the help, version, missing-bundle and `ContainerizationError` paths are untested. That gap let F-01 and F-03 through | A ParbakeExitTests row per path, plus one test that runs the binary for its streams (R1.1–R1.2) |
| F-07 | Warn | A | docs/end_to_end_checklist.md:51,57,64,65 | Steps 10, 17 and 18 expect what cannot happen, and step 7's command is not what ran. The record cannot go green | R2.2 |
| F-08 | Warn | A | .agents/plans/plan_release_audit_stage1.md (S-005, S-013 rows) | S-005 assumes a reboot stops the VM. S-013 assumes the `Agent` file drives the warning | R2.2 |
| F-09 | Warn | A | docs/adr/adr_0010_keychain_access_follows_the_signing_identity.md:32 | PII: the identity line shows a personal email (CWE-359) | Redact to `<account>` (R2.3) |
| F-10 | Warn | A | Tests/RuntimeMacOSTests (missing file) | The C-004 LogSubsystem test is absent | R1.6 |
| F-11 | Warn | A | Sources/RuntimeMacOS/MacOSVMBundle.swift:309-325 | The `resetOverlay` swap renames file by file, so a mid-loop failure leaves a mixed instance. The doc comment claims otherwise | R1.5 |
| F-12 | Warn | A | Sources/RuntimeMacOS/GuestPreparation.swift:43,52 | `script()` interpolates `sudoCommands` without checking them (CWE-78/74 hardening; callers check) | R1.4 |
| F-13 | Warn | A | Sources/parbake/Create.swift:251; Provision.swift:74; Agent.swift:51; Layer.swift:49 | Precondition failures are `ValidationError`, so they exit 64 with the usage banner | `ParbakeError.runtime` or `RuntimeFailure` |
| F-14 | Warn | A | Sources/parbake/ParbakeExit.swift:27 | Any `ContainerizationError` exits 1, whatever the taxonomy says | An explicit branch, or a test row stating 1 |
| F-15 | Warn | A | Tests/RuntimeMacOSTests/BundlePathPolicyTests.swift | Edge cases have no test: a symlinked root, `/` as a root, a bundle equal to a root, a `Layer.asif` link, and a wrong owner on layout files. Assertions are weak | Add the rows and assert the case |
| F-16 | Warn | A | Tests/ParbakeTests/ProvisionInputsTests.swift | Tests assert `throws: (any Error)` and do not pin 64 | Assert `ValidationError` |
| F-17 | Warn | A | Tests/RuntimeMacOSTests/GuestShellTests.swift:48-75 | `GuestShell.sshPath` is a process-global `nonisolated(unsafe)` seam that other suites can race | Inject the path per call |
| F-18 | Warn | A | Tests/RuntimeMacOSTests/GuestShellTests.swift | Not covered: SIGKILL escalation, large bidirectional output, the environment, and the stdin status | Add stubs (`trap '' TERM`, `env`) |
| F-19 | Warn | A | Tests/RuntimeMacOSTests/GuestProvisioningTests.swift:~149-195 | No test that preflight never creates the probe account. Missing `classify` rows. No hostile table for the `security` arguments and the script builders | Add the rows |
| F-20 | Warn | A | Tests/RuntimeMacOSTests/DHCPMessageTests.swift:36-47 | Missing cases: an oversized frame, a zero-length option, an end marker without option 53, a pad before 53, an unknown 53 value, and option 50 with a length other than 4 | Add the cases |
| F-21 | Warn | A | Sources/RuntimeMacOS/FileLock.swift:50-58 | The wait path is untested. It polls with `usleep` and hardcodes "download" in the notice | Test with a latch; let the caller pass the text |
| F-22 | Warn | A | Sources/container-runtime-macos/RuntimeService.swift:311-318 | An unknown signal on a stopped container says "unknown signal", not Q17's "not running" | Check the state first |
| F-23 | Warn | A | Sources/container-runtime-macos/RuntimeService.swift:323-336 | The refusal error code is decided inline and untested | Move it into `RuntimeLifecycle` |
| F-24 | Warn | A | Sources/container-runtime-macos/RuntimeService.swift:548-555 | "forceStop wins" is not enforced. The detached ssh is not cancelled and holds a pool thread for up to 60 s. The identity check is always true | A force-stopped flag, plus cancellation that terminates ssh |
| F-25 | Warn | A | Sources/container-runtime-macos/RuntimeService.swift:326-329 | `requestStop` after `shutDown` can throw on a guest that already stopped (kill TERM race) | Re-check the state |
| F-26 | Warn | A | Sources/container-runtime-macos/RuntimeService.swift:193-204 | R4: the `.prepared` check, then an await, then `.running`. A second start can slip through | A `.starting` state |
| F-27 | Warn | A | Sources/container-runtime-macos/RuntimeService.swift:493 | A 5 s `container stop` caps the shutdown request at 5 s. Against ADR 0003's 60 s, a slow acceptance falls back to the power button | Give the request its own floor, or document the cap |
| F-28 | Warn | A | Sources/container-runtime-macos/RuntimeService.swift:~553; Sources/parbake/Provision.swift ("Last ssh error") | Guest-controlled ssh stderr is logged `.public` (CWE-117/532/150) | Cap the length and escape control characters |
| F-29 | Warn | A | Sources/RuntimeMacOS/GuestCredentials.swift:90-135 | `creatorOnly` reads an old `-A` item and never tightens it (CWE-732) | Re-store it on read under `.creatorOnly` |
| F-30 | Warn | A | Sources/RuntimeMacOS/GuestCredentials.swift:25-27; RuntimeLifecycle.swift:60 | Runtime messages point at repo paths ("see docs/signing.md", "see README › Limitations") | Name the action instead |
| F-31 | Warn | A | docs/adr/adr_0004_*, adr_0009_* | DOC-TYPE-01: no `doc_type` declaration on changed pages | Add `<!-- doc_type: explanation -->` |
| F-32 | Warn | A | docs/adr/adr_0009_module_boundaries_and_one_version_target.md | Stale text: a lint in a Taskfile check, and `public import` | Amend |
| F-33 | Warn | D | docs/adr/adr_0009_…md:5 | `Proposed` while implemented, with every box unchecked | Decider: accept? |
| F-34 | Warn | D | Sources/container-runtime-macos/RuntimeService.swift:129-135; BundlePathPolicy.swift:23 | TOCTOU between validate and open; the roots file's `stat` follows a symlink (CWE-367/59) | Is the same-uid window accepted? |
| F-35 | Warn | D | Sources/RuntimeMacOS/SigningIdentity.swift:11-20 | Any Security API failure falls open to `.adHoc`, the weaker ACL | Fail closed, or log? |
| F-36 | Warn | D | Sources/RuntimeMacOS/SigningIdentity.swift | Any team ID counts as `.team`; none is pinned | Bind to one team? |
| F-37 | Warn | D | Sources/RuntimeMacOS/GuestShell.swift (`threads.wait`) | A grandchild holding the pipes can block past the timeout | Kill the process group? |
| F-38 | Warn | D | Sources/parbake-agent/GUISession.swift:20-25; GuestProcess.swift:319 | A synchronous `launchctl print` runs per exec for a non-root account | Cache it? Check the caller's queue |
| F-39 | Warn | D | Sources/RuntimeMacOS/MacOSVMBundle.swift:115 | A tampered `Provisioned` file reads as absent | Fail loudly? |
| F-40 | Warn | D | docs/adr | No ADR for the bundle-roots format, the exit-code table or the os_log names (one-way doors) | Is the README the record? |
| F-41 | Warn | D | Sources/container-runtime-macos/OSLogHandler.swift | Untested, because the executable target has no test target | Stage 2, or move it into RuntimeMacOS |
| F-42 | Warn | D | Sources/RuntimeMacOS/RuntimeFailure.swift:27 | The keychain-locked hint assumes a human at the host | Add an auto-login hint? |
| F-43–F-60 | Suggest | A/D | various | Lint `signal(` anchoring; a Taskfile identity in `sh` and a hash identity; a HostRequirements probe without a timeout; `kSecUseAuthenticationUIFail` deprecation; `testTheTestBinaryIsAdHocSigned` gating; the `GuestCredentials` usleep poll; the cached `access` default; FileLock 0644 and `O_NOFOLLOW` (CWE-532/59); staging names; `classify` substring matches; the `--sudo` "any arguments" wording (CWE-269); the `restrictsWithStableIdentity` constant; ADR 0011 boxes; SECURITY.md:44-45 rationale; the spec Status wording; DHCP test names; temp-dir cleanup; CRLF in the roots file | see the seat reports; none gates |

### Convergence

Unmet IDs are appended as rows R1 (wave 3) and R2 (wave 4) in the plan's Parallelization table, with Steps entries.

- C-004 partial: no test.
- C-012 partial: 66 is never emitted; help goes to stderr and is logged at error.
- C-013 partial: `script()` accepts `sudoCommands` it has not checked.
- C-021 partial: the `resetOverlay` swap is not atomic.
- C-040 partial: the stdin password is read after the download (H-08).
- C-050 partial: there is no identity for `parbake` alone, though the docs prescribe it (Q20).
- C-060 contradicts: the README 66 row and keychain line, ADR 0008's 66 row, CHANGELOG:12.
- C-062 partial: the expectations of steps 7, 10, 17 and 18.
- S-005 contradicts: the scenario expects "guest stopped" after a reboot, and the VM restarts in place.
- S-013 contradicts: the scenario's trigger (the `Agent` file) is not what C-031 compares.
- C-071 partial: the record shows 17 of 20, and the expectations need R2.

### Fold-Back

not performed — the verdict is not Approve, the plan is unconverged, and the run did not write the terminal state.
The plan also has no `## Spec Deltas` block.

### Cross-Model Adversarial

Skipped: no adversary is pinned in `hex.md`, and no second harness is on `PATH`.

### Root-Cause Analysis

- **R-A: docs and the checklist were written from the plan's contracts and not verified against the shipped binary.**
  Findings: F-01, F-02, F-05, F-07, F-08, F-09.
  - Why 1: the 66 row was copied from C-012's table.
  - Why 2: C-012's row had no test naming a throw site.
  - Why 3: the contract tests check `RuntimeFailure.exitCode`, not which paths reach it.
  - Why 4: no harness runs `parbake` against a missing bundle.
  - Why 5: the P7 validation recorded failures without folding the expectation fixes back.
  - Systemic fix: every row in a documented exit-code or error table carries a test that reaches it through the
    binary. The e2e protocol fixes the checklist expectation in the same pipeline that records a "wrong
    expectation" failure.
- **R-B: the plugin's actor glue has no test seam.** Findings: F-22 to F-27, F-41.
  - Why: decisions sit inline in `RuntimeService`, whose executable target has no test target (stage 2 S2.1).
  - Systemic fix: move each decision into `RuntimeLifecycle`, and add the plugin test target in stage 2.
- **R-C: the custom `main` reimplements ArgumentParser's error routing.** Findings: F-03, F-06, F-13, F-14.
  - Why: the guard lists error types (`CleanExit`) instead of asking `exitCode(for:)`. `HelpCommand` throws an
    internal `CommandError`.
  - Systemic fix: key the guard on the library's classification, and add a stream and exit test.
- **R-D: builders trust their callers' validation.** Findings: F-04, F-12, F-29.
  - Systemic fix: each builder checks its own input, which the plan's C-013 title already says.
- **R-E: plan edge-case lists were not turned into tests.** Findings: F-15, F-16, F-18, F-19, F-20, F-21.
  - Systemic fix: each edge-case bullet in a contract names its test.

### Deferred Findings (human judgment required)

F-33 to F-42 above, plus these:
- Is the README the contract of record for the one-way doors (F-40)?
- Should the stale-agent warning also read the bundle's `Agent` file (S-013)?
- Should the MAC be persisted per instance? It would keep IPv6 and the guest NIC stable and may help save/restore.

## Trace check of the full-repo review

Each row is fixed, deviation (a deliberate deviation recorded in an ADR) or open.

| ID | Status | Evidence |
|---|---|---|
| B-01 | fixed | README lists the three chained `create` steps, then the standalone commands |
| B-02 | fixed | AGENTS.md names three executables and their entitlements; Taskfile.yml:57-59 matches |
| B-03 | fixed | docs/architecture.md:38-49 describes both branches |
| B-04 | fixed | spec_guest_agent C-005 lists the real routes; stdin closes with the stream; delete is internal |
| H-01 | fixed | atomic `instance(at:)` with RENAME_EXCL; kind-aware `init(url:)`; the base is never opened read-write |
| H-02 | fixed | SIGPIPE ignored at ParbakeTool.swift:26 and parbake-agent/main.swift:7, enforced by lint |
| H-03 | fixed | ssh shutdown in `Task.detached` with a timeout; GuestShell timeout with SIGTERM then SIGKILL |
| H-04 | fixed | pin at the `parbake` tip with 3b9b5b75, 13ff2d85 and 0f824548; CI cache key; docs list all three |
| H-05 | fixed | `mapStartError` in both start paths; `vmLimitReached` text with "slot" |
| H-06 | fixed | `initSignalAction` gives `.forceStop` for KILL while stopping |
| H-07 | fixed | 60 s wait, two messages, ADR 0008 row |
| H-08 | **open** | the stdin password is still read after the install (F-04) |
| H-09 | fixed | target lock and cache lock; `build(replacing:false)` keeps the target |
| H-10 | fixed | `GUISession.require` in GuestProcess.swift:319 gives FAILED_PRECONDITION |
| H-11 | fixed | mounts, ports and sockets refused at bootstrap; README › Limitations lists the ignored inputs |
| H-12 | **open** | ParbakeError and the exit table exist, but the documented 66 is unreachable, and four precondition sites still exit 64 with the usage banner (F-01, F-13) |
| H-13 | fixed | `GuestUsername` on read; `--` terminator; IPv4 check |
| H-14 | fixed | `ScriptInput.check` on password, keys and username; hostile tests. The builder-level `sudoCommands` check is F-12 |
| H-15 | fixed | about 20 mutation cases; the parser needed no change. More cases in F-20 |
| H-16 | fixed | README Requirements: fork tag, `dev-env.sh build`, CONTRIBUTING link, stock release unsupported |
| H-17 | fixed | README Build and install, and Run |
| H-18 | fixed | README Remove everything |
| H-19 | fixed | the agent path, `/var/log/parbake-agent.log` and the log predicate are documented |
| H-20 | fixed | dev-env.sh parts documented |
| H-21 | fixed | config keys documented |
| H-22 | fixed | standalone command flags documented |
| H-23 | fixed | SECURITY.md and CHANGELOG.md exist |
| H-24 | fixed | `classify` plus keychain preflight before the download |
| H-25 | fixed | `.keychain`, `.hdiutil` and `.asif` traits on the host suites |
| D-01 | fixed | `BundlePathPolicy` (home plus the `bundle-roots` file) applied at bootstrap. The residual TOCTOU is F-34 |
| D-02 | deviation | ADR 0011 accepts an absolute-path `--sudo` rule that still grants the program with any arguments, and records the provisioning config. `SudoCommand` enforces it |

Summary: **28 fixed, 1 deviation (D-02), 2 open (H-08, H-12).**

## Host-run defects

| # | Defect | Grade | Evidence | Minimal fix |
|---|---|---|---|---|
| 1 | Step 10: the guest address changes on restart (.4 to .13) | **Wrong expectation, over an external limit** | The plugin calls `allocate(hostname:macAddress:)` on each start with the config's MAC, nil by default (RuntimeService.swift:412-424). apple/container draws a random MAC when none is passed (`DefaultNetworkService.swift:72`). It frees the index on release, and `AttachmentAllocator` uses a rotating allocator (`AttachmentAllocator.swift:52,100-125`). The plugin cannot keep the IPv4 | Checklist: step 10 expects an address after the restart, not the same one. One line in ADR 0002's consequences. Optionally persist a MAC per instance, which keeps the MAC and IPv6 but not the IPv4 |
| 2 | Step 17: an in-guest reboot ends `exec` with "guest kept running" after 66 s | **Wrong expectation** | A macOS guest reboot restarts inside the same VM. `guestDidStop` fires only on halt (MacOSVirtualMachine.swift:430-436; Apple documents no reboot callback). `processExit` waits 60 s and then gives C-030's alternative message (RuntimeLifecycle.swift:44). The code follows S-005's alternative branch | Checklist and S-005: expect "kept running" within about 70 s, or use `shutdown -h now` for "guest stopped". Add an ADR 0008 row: a reboot inside a job ends `exec` as lost |
| 3 | Step 18: no stale-agent warning | **Wrong expectation (method)** | The warning compares the live agent's reported release with `Parbake.release` (RuntimeService.swift:213-221). Writing `1` into `Agent` changes only the recorded file, never the running agent | Checklist and S-013: use a guest whose installed agent comes from an older or differently versioned build. Optionally also warn on the bundle's `Agent` line (deferred) |
| 4 | A team-signed plugin cannot start vmnet DHCP (status 1001, "different security domains"), so the plugin runs ad hoc | **External limit** (vmnet and InternetSharing between an ad-hoc network helper and a team-signed client), plus a project gap: no supported mixed signing (F-05) | The failure is at `vmnet_network_create_with_serialization` and the DHCP start (RuntimeService.swift:418-425). No Apple doc names the message; the cause is inferred. Recorded in docs/signing.md:66-70 and dev-env.sh:36-37, in no ADR | Taskfile: a separate `parbake` identity, with the plugin ad hoc by default. Record the limit in ADR 0010's consequences. Test once: signing the network helper and the plugin with the same team ID |
| 5 | `--help` logged at error level | **Code defect** (reproduced: `parbake --help` writes `Error: OVERVIEW…` to stderr, rc 0) | `parseAsRoot` returns `HelpCommand`, whose `run()` throws `CommandError` (swift-argument-parser 1.8.2, `CommandParser.swift:419-423`, `HelpCommand.swift:32-36`). It misses the guard at ParbakeTool.swift:41 and is printed and logged at :42-44 | Code: `if ParbakeTool.exitCode(for: error) == .success { exit(withError: error) }` before the custom path, plus a stream test (R1.1) |

## Next step

    /hex-execute .agents/plans/plan_release_audit_stage1.md "apply xhigh-tier review findings"
