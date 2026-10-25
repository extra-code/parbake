# Research: Stage 2 release-audit review

Range: `bcef49a..1ff0d8d` on `hex/release-audit` (64 commits; code ends at `9214eae`). Tier: xhigh (auto).
Spec: `.agents/plans/plan_release_audit_stage2.md`. This report replaces the partial record of the review of
`bcef49a..deeff1f`, whose findings were lost.

## Status of this record

Complete. Written incrementally after each stage; the synthesis below supersedes the per-seat raw sections, which stay
for evidence.

- [x] Config resolved and announced
- [x] Stage 1 (correctness, convergence) — 6 seats returned
- [x] Stage 2 (panel) — 6 seats returned
- [x] RCA, convergence, verdict

## Resolved config

```
hex-review
  Tier:      xhigh        (auto — 95 files, +6305 / -756 lines, 5 source areas + tests, scripts, docs)
  Baseline:  bcef49a      (user --base)
  Target:    HEAD 1ff0d8d (branch hex/release-audit)
  Overlays:  breadth=adversarial (tier baseline), rca=on (tier baseline), adversary=on (tier baseline)
  Spawn set (Stage 1, one batch):
    reviewer: spec post-implementation + convergence, slice CW+PV (RuntimeMacOS core)
    reviewer: spec post-implementation, slice PH (guest I/O)
    reviewer: spec post-implementation, slice PP+PR (plugin, incl. the 9214eae fix)
    reviewer: spec post-implementation, slice PA+PCLI+PC+PD+PE
    reviewer: quality (test-coverage), whole range
    reviewer: spec (seams + behaviour preservation + stage 1 regression spot-check)
  Spawn set (Stage 2, one batch):
    reviewer: user-feedback (CLI messages and exit codes touched)
    reviewer: security       (tier baseline; hex.md perspectives.always on RuntimeMacOS, plugin, scripts, Taskfile)
    reviewer: performance    (tier baseline)
    doc-reviewer             (tier baseline)
    architect                (tier baseline; ADR 0009, ADR 0014 incl. the SW-IO-05 deviation)
    researcher: pitfalls     (tier baseline; Foundation.Process, pipes, signals, actor reentrancy)
  Models:    standard (sonnet), all seats
  Adversary: none configured in hex.md — Cross-model review skipped: no adversary pinned
  Gate:      meta-plan gate pre-approved by the caller; announced, not blocked
  Degraded:  no
```

## Decisions taken by this run (question → decision)

- Pipeline split: 9 pipelines would give 18+ Stage 1 seats → grouped into four slices by module (CW+PV, PH,
  PP+PR, the rest), one test-coverage seat over the range and one seams seat. Stays inside the 8-worker cap.
- The plan carries a `Repo` column whose every value is `—` and `hex.md` has no Federation bullets → treated as a
  single-repo plan (the lead); no federation halt, no union scope.
- Gate evidence: `task clean check` exit 0 at `9214eae` (caller). Seats may run one targeted test each, never
  the suite. No VM boots.
- Stage 2 launched while the seams seat was still running (5 of 6 Stage 1 seats in), to bound wall time; the seams
  seat's results fold into synthesis like any other.
- Commits after `9214eae` touch only `.agents/` records; they are reviewed as records, not code.

## Summary

- **Verdict: Request Changes.** No Block, but 3 actionable High findings, and two systemic causes each behind three or
  more findings (R-A, R-D below), which the xhigh verdict rules map to Request Changes. The review did not converge.
- Tier xhigh (auto) · Baseline `bcef49a` · Diff 95 files, +6305 / -756 lines, five source modules plus tests, scripts
  and docs.
- Cross-model review skipped: no adversary is pinned in `hex.md`.
- Counts: **0 Block · 4 High (3 actionable, 1 deferred) · 33 Warn (30 actionable, 3 deferred) · 12 Suggest.** Dropped:
  2 stated-convention or pre-existing, 1 pre-existing out of scope.
- **C-142/C-144 fix (9214eae): partially fixed.** C-144 is fixed: the text "guest rejected the stop request" is
  byte-identical to 12aa486 at warning level, and the tests are real. C-142's boot path is fixed with real tests. But
  the new `abandonStart` call on the readiness exit (H-1) force-stops a guest whose graceful stop is in progress.
- **Behaviour preservation:** about 60 error sites were mapped from 12aa486 to HEAD. Text and code are identical except
  for the recorded decisions, the DHCP code drift (H-2), the exit-64 wrapper text (W-22), and one benign improvement.
- **ADR 0014's SW-IO-05 deviation: justified with gaps** (W-15, W-16, W-17, D-3, S-5).
- **Stage 1 contracts:** F-01, F-02, F-03, F-04, F-05, F-06 and the C-020 bundle-path policy all hold at HEAD.
- **Architecture:** module boundaries are clean, `scripts/lint-boundaries.sh` exits 0, and no ADR is contradicted
  except ADR 0014's own claims (W-14, W-25).

## Findings (synthesized; one line each)

### High

| ID | File:line | Issue → fix | Actionable |
|---|---|---|---|
| H-1 | Sources/container-runtime-macos/RuntimeService.swift:250-253 | A stop during the agent-readiness wait runs the graceful ladder; when readiness returns, `abandonStart` force-stops the guest mid-shutdown and closes the agent. → Throw `stoppedWhileStarting` there without `abandonStart`; keep it for the boot exit (:217); test stop-during-readiness | yes |
| H-2 | Sources/container-runtime-macos/RuntimeService.swift:145 | `allocateNetwork` runs outside any conversion; DHCP `RuntimeFailure.internalError` reaches XPC as `.unknown` (12aa486: `.internalError`). → Wrap in `RuntimeLifecycle.containerizationError`; add a route test | yes |
| H-3 | Tests/RuntimeMacOSTests/HostProcessTests.swift:73-77 | `trap '' TERM` with a 200 ms timeout asserts 137; a slow `sh` start gets SIGTERM before the trap → 143, flake. → Signal readiness after the trap before timing, or assert `timedOut` and accept 137 or 143 | yes |
| H-4 | docs/end_to_end_checklist.md step 15 | The boot from `<volume-bundle>` was skipped (removable-volume prompt); C-180 "steps 1–20 pass" and the release gate are open | no — needs an attended run or an amended C-180 |

### Warn — actionable

| ID | File:line | Issue → fix |
|---|---|---|
| W-1 | scripts/coverage.sh:90 | `otool -l \| grep -q` under pipefail can fail with SIGPIPE and skip a bundle → `grep -c` / `>/dev/null`, or capture first |
| W-2 | scripts/coverage.sh:108-112 | A failed `llvm-cov export` still prints an all-zero table → export to a temp file, check, then aggregate |
| W-3 | Sources/RuntimeMacOS/GuestReachability.swift:28 | No final probe after the last sleep; lock retry makes 15 attempts, not 16 → drop the post-sleep check or record it |
| W-4 | Sources/RuntimeMacOS/GuestShutdown.swift:41-45 | `note(.requestStop)` fires on the benign stopped-meanwhile race → skip when `currentExit != nil`; test |
| W-5 | Tests/RuntimeMacOSTests/GuestShellTests.swift | No assertion for the sync `run`'s 128 + signal → self-killing stub, expect 143 |
| W-6 | Tests/RuntimeMacOSTests/HostProcessTests.swift | No `timeout: .zero`, empty input, or closed-stdin-with-pending-input test → add them |
| W-7 | Tests/RuntimeMacOSTests/HostProcessTests.swift (cancellation) | Only cancel-before-attach is exercised → cancel after the child signals it is up |
| W-8 | Tests/RuntimeMacOSTests/ExitLatchTests.swift:16-37 | `finish` usually runs before the waiters register; no timed-wait race → register first, then finish |
| W-9 | Tests/RuntimeMacOSTests/ExitLatchTests.swift:41 | 1 ms real-time wait → inject a clock, or accept |
| W-10 | Tests/ParbakeAgentTests/Support/AgentFixtures.swift:61-70 | socketpair peers leak on a failed assertion → `deinit` closing every peer |
| W-11 | Tests/ParbakeAgentTests/SandboxServiceTests.swift:95-112 | `sleep 60` children outlive a failed assertion → `defer` kill |
| W-12 | Tests/ContainerRuntimeMacOSTests (route suites); GuestShutdownTests.swift:84,95 | No concurrent-stop, KILL-vs-stopping, or shutdown-before-stop test; note payload unasserted → add them |
| W-13 | RuntimeService.swift:146-151; RuntimeEnvironment+Live.swift:96-99 | "allocated guest address" logged twice → keep one |
| W-14 | docs/adr/adr_0014_…md (Decision Outcome, Errors) | Claims `RuntimeFailure` is the only `Error` type; `ProbeError` exists (GuestReachability.swift:2) → state the exception or change the payload type |
| W-15 | ADR 0014 (Consequences) | Deviation cost unstated: the project owns a hand-written runner → one Negative bullet |
| W-16 | Sources/parbake-agent/AgentCommand.swift:9-20 | Drain-only, no bound; ADR says runs are timed out and cancelled in one place → state the exception, or add a bound |
| W-17 | ADR 0014 (follow-up) | swift-subprocess follow-up has no trigger → name a trigger and where it is tracked |
| W-18 | Sources/parbake/AgentSetup.swift:41-44; AgentProbe.swift:92 | Ladder called without `note`; a failed forced stop is silent → print it to stderr |
| W-19 | RuntimeService.swift:508-510 | "…, stopping it" now logged after the forced stop → reword or move |
| W-20 | Sources/RuntimeMacOS/RuntimeFailure.swift:52-53 | `guestStopped` text names no next step → append one; update goldens |
| W-21 | Sources/RuntimeMacOS/GuestReachability.swift:51,62 | Interrupted wait prints "CancellationError()" → drop the cause for cancellation (or rethrow it) |
| W-22 | Sources/parbake/ProvisionInputs.swift:24,79 | Exit-64 text lost its `invalidArgument: "…"` shape (unrecorded) → record the decision or restore it; pin with a test |
| W-23 | Tests/RuntimeMacOSTests/RuntimeMacOSErrorTextTests.swift (private constructors); RuntimeFailureGoldenTests.swift (`forwarded`) | Rows pin the test's own copy, not the production site → drive real sites, or label as text pins |
| W-24 | README.md:276; CHANGELOG.md:23 | "stop while it boots force-stops" holds only until the VM boot returns → narrow the wording |
| W-25 | ADR 0014 (Poll interval, ~190-193) | "one default of 3 s" holds only for `waitForSSH` → name the 1 s and 2 s intervals |
| W-26 | Sources/RuntimeMacOS/GuestShell.swift:136 | "as it always did" (history) → present tense |
| W-27 | ADR 0014 (Implementation/Validation, ~232-242) | Boxes unchecked on an Accepted ADR → tick those that hold |
| W-28 | Sources/RuntimeMacOS/ExitLatch.swift:65-68 | Two uncancelled unstructured tasks per timed wait → task group with `cancelAll()` |
| W-29 | Sources/RuntimeMacOS/GuestReachability.swift:25-26 | Sleep not clamped to the deadline; in-flight probe unbounded → clamp; bound `reach` |
| W-30 | Sources/RuntimeMacOS/HostProcess.swift:163,188,193 | Dispatch (awake-time) timeouts vs ContinuousClock deadlines → document or unify |

### Warn — deferred (human decision)

| ID | File:line | Question |
|---|---|---|
| D-1 | RuntimeService.swift:325-346, 495-512 (with abandonStart 264-269) | At 12aa486 a failed forced stop made `stop` fail; now `stop` succeeds and the state is `.stopped` while the guest may run (recorded as "the ladder ignores errors"). Accept log-only, or surface the failure / keep `.stopping`? |
| D-2 | Tests/RuntimeMacOSTests/GuestShellTests.swift:62-76 | Keep the upper wall-clock bounds (`< 5 s`, `< 8 s`, `< 10 s`), or drop them and rely on `timedOut`/status plus `.timeLimit`? |
| D-3 | .claude/rules/swift-quality.md row 18 / ADR 0014 | Accept a recorded project-level SW-IO-05 deviation, or propose a second named legacy reason via `/hex-retro`? |

### Suggest

S-1 HostProcess stdin is now /dev/null (curl, security) — note it in Status · S-2 GuestReachabilityTests zero-timeout
and exact-deadline cases · S-3 GuestShellTests 4 MB test duplicates HostProcess's · S-4 (security, deferred) the SSH
password goes to ssh through the environment, as at 12aa486 (CWE-526) — is an fd/keychain askpass planned? · S-5
`// legacy:` comments name no reason · S-6 ADR 0014: say why the eight generic `RuntimeFailure` cases exist · S-7
rename `note` → `onStepError` · S-8 Provision.swift:142 one validator for the key · S-9 BundlePathPolicy `try?` yields
"links to , outside…" · S-10 RuntimeEnvironment+Live.swift:73 `try?` hides a decode cause · S-11 record Provision's
5 s → 3 s poll in Status · S-12 HostProcess late `cancel()` / pid check (CWE-367, nanosecond window).

## Convergence

- C-142 **partial** — the readiness-wait exit force-stops a guest that a graceful stop owns (H-1). S-103 is
  partial with it.
- C-146 **partial** — `allocateNetwork` errors reach XPC as `.unknown`, not `ContainerizationError` (H-2). S-106 is
  partial with it (code parity).
- C-180 **partial** — checklist step 15's boot from the volume was not run (H-4). S-108 is partial with it.
- Every other ID (C-101..C-107, C-110..C-114, C-120..C-126, C-130..C-134, C-140, C-141, C-143..C-145, C-150..C-153,
  C-160, C-170, C-171, S-101, S-102, S-104, S-105, S-107) is met, with recorded deviations. Nothing unrequested of
  substance.
- Appended to the plan's Parallelization table: rows **PR2** (C-142, C-146; S-103, S-106) and **PE2** (C-180, S-108;
  needs an attended run or a human decision to amend C-180).

## Fold-Back

Not performed: the verdict is not Approve, the review is unconverged, and the plan has no `## Spec Deltas` block.

## Cross-Model Adversarial

Cross-model review skipped: no adversary is pinned in `hex.md` (no second harness on `PATH`).

## Root-Cause Analysis (clusters; every finding above Suggest belongs to one)

- **R-A — parity is pinned with copies, not through the production boundary.** H-2, W-22, W-23 (and W-13).
  - Why 1: the plugin's DHCP code drifted with no red test.
  - Why 2: the golden rows build the error, or wrap it, inside the test.
  - Why 3: the plan asked for golden tables of texts and codes, not route-level assertions per site.
  - Why 4: the conversion rule ("convert in one function") has no structural guard at each route's entry.
  - Why 5: route tests cover the routes' happy and refused paths, not every collaborator's failure.
  - Systemic fix: one route test per environment closure that throws a `RuntimeFailure` and asserts the XPC code. Or
    convert inside every `.live` closure, so the boundary cannot be bypassed.
- **R-B — the ladder turned failures into notes without a reporting contract.** W-4, W-18, W-19, D-1.
  - Why 1: a failed forced stop is silent (parbake), or reports success (plugin).
  - Why 2: `GuestShutdown.run` returns `.forced` whatever happened.
  - Why 3: `note` defaults to a no-op, so callers can omit it.
  - Why 4: C-106 defined outcomes, not failures.
  - Why 5: the shared helper replaced four ladders whose error handling differed.
  - Systemic fix: return the failure in the outcome (for example `.forced(error: (any Error)?)`) so every caller must
    decide. Also skip benign races in one place.
- **R-C — two owners of one guest in the start/stop state machine.** H-1, W-12, W-24.
  - Why 1: `abandonStart` force-stops a guest whose stop is graceful.
  - Why 2: the PR step asked both stopped-while-starting exits to force-stop.
  - Why 3: the readiness wait runs in `.running`, so the stop path differs by phase.
  - Why 4: no test interleaves a stop with the readiness wait.
  - Why 5: the interleaving list in C-142 named only the boot.
  - Systemic fix: give the state machine one owner of the guest per phase, written down in the State doc comment.
    Then add a test per (route × await point) pair.
- **R-D — real time and unordered events in tests and timeouts.** H-3, W-7, W-8, W-9, W-29, W-30, D-2.
  - Why 1: tests race process start-up or waiter registration against short timers.
  - Why 2: HostProcess and ExitLatch have no injectable clock or arrival hook.
  - Why 3: C-102 specified behaviour with real children.
  - Why 4: two time bases coexist (Dispatch and ContinuousClock).
  - Why 5: no project rule names the time base for child timeouts.
  - Systemic fix: a readiness handshake for process tests, an arrival hook on ExitLatch, and one documented time base.
- **R-E — ADR 0014 was written in wave 1, before the code settled, and not re-validated at merge.** W-14, W-15, W-16,
  W-17, W-25, W-27, D-3.
  - Systemic fix: re-run the ADR's Validation list at the integration gate, and tick it or amend the ADR.
- **R-F — new runners lack edge and cleanup tests.** W-5, W-6, W-10, W-11.
  - Systemic fix: a test fixture that owns and closes every fd and child, plus the edge list from the plan's Edge
    cases section turned into tests.
- **R-G — script error paths print before they check.** W-1, W-2.
  - Systemic fix: capture each step, check its status, then print.
- **R-H — poll deadline semantics.** W-3, W-29.
  - Systemic fix: define `poll` as "probe at once, then every `every`, with a last probe at the deadline, never past
    it" and test the boundary.
- Singletons: W-20, W-21, W-26, W-28 (proximate causes as stated).

## Deferred Findings (human judgment required)

H-4, D-1, D-2, D-3, S-4. The questions are in the tables above.

---

## Raw findings per seat (evidence; severities as raised, merged above max-wins)

### Stage 1 — slice PA+PCLI+PC+PD+PE (spec)

Coverage 15/16. C-110..C-114, C-150..C-153, C-160, C-170, C-171 met; C-180 partial (step 15's boot from the volume
not run). Unrequested: none of substance (`PseudoTerminal.resize` extraction supports C-111).

- [High, deferred] docs/end_to_end_checklist.md step 15 — the boot from `<volume-bundle>` was skipped (removable-volume
  prompt), so C-180 "steps 1–20 pass" and the release gate are open. Question: re-run step 15 interactively, or accept
  the partial and amend C-180/S-108.
- [Warn, actionable] scripts/coverage.sh (~97) — `otool -l | grep -q __llvm_covmap` under `pipefail` can fail with
  SIGPIPE and skip a bundle as "no coverage data". Fix: `grep -c`/`>/dev/null` or capture first.
- [Warn, actionable] scripts/coverage.sh (~108-112) — a failed `llvm-cov export` still prints an all-zero table before
  the non-zero exit. Fix: export to a temp file, check status, then aggregate.

### Stage 1 — slice PP+PR (spec), including the 9214eae fix

Coverage 7/7 contracts delivered; C-142 partial because the fix added a defect. C-144 fixed: "guest rejected the stop
request" is byte-identical to 12aa486, warning level, tests real. C-142 boot path fixed with real tests.
Fix verdict: **partially fixed**. Orchestrator re-read RuntimeService.swift:196-275 and 324-350 and confirms the High.

- [High, actionable] Sources/container-runtime-macos/RuntimeService.swift:250-253 (abandonStart 262-271) — a stop that
  arrives while `startProcess` waits for agent readiness finds `.running`, sets `.stopping` and runs the graceful ladder.
  When readiness returns, the guard at 250 calls `abandonStart`, which force-stops the guest in the middle of its
  graceful shutdown and closes the agent under the in-flight `agent.shutDown`. At deeff1f that guard only threw. Fix:
  at 250 throw `stoppedWhileStarting` without `abandonStart` (the stop owns the guest; its ladder ends in forceStop and
  `guestStopped` closes the agent); keep `abandonStart` for the boot exit at 217 only. Test: stop during the readiness
  wait, then release `waitUntilReady`; assert `forceStop` only through the ladder and no early `close`.
- [Warn, actionable] RuntimeService.swift:146-151 and RuntimeEnvironment+Live.swift:96-99 — "allocated guest address" is
  logged twice on `.live`; 12aa486 logged it once. Fix: drop the log in `LiveNetwork.allocate`.
- [Warn, deferred] RuntimeService.swift:338-343 with abandonStart 264-269 — if both forced stops fail, the state is
  `.stopped` and `container stop` succeeds while the guest may still run; only the log records it (recorded PR
  decision). Question: is log-only acceptable, or should the second failure surface as an error?
- Not a finding (pre-existing, 12aa486): RuntimeService.swift:239-248 readiness-wait catch branches ignore state, so a
  stop during the wait reports `.timeout` instead of `.interrupted`. Out of scope; noted for the same fix.
- Gap check: "stop during the readiness wait then `abandonStart`" — confirmed untested (it hides the High). "The
  `currentExit` skip" — refuted on the boot path: `testStopWhileTheGuestBootsForceStopsItAndEndsTheStartInterrupted`
  asserts one `forceStop`; uncovered only on the readiness path.

### Stage 1 — slice CW+PV (spec)

Coverage 12/12 (C-101..C-107, C-130..C-134) with the recorded deviations. Goldens (639e242) precede the moves and match
12aa486. Verification greps clean: `ContainerizationError(` only RuntimeLifecycle.swift:80; `Process()` only
HostProcess.swift:113 and AgentCommand.swift:9; `shutdown -h now` and `sudo -S` only GuestCommands.swift.
`Package.resolved` unchanged.

- [Warn, actionable] Sources/RuntimeMacOS/GuestReachability.swift:28 (via MacOSVirtualMachine.swift:182) — `poll`
  returns nil after the last sleep without a final probe, so the aux-storage retry makes 15 attempts in 30 s where
  12aa486 made 16 (a last start at the deadline). Orchestrator confirmed against `git show 12aa486`. Fix: drop the
  post-sleep deadline check (the loop-top probe and the check at :26 bound the loop), or record the change in ADR 0014.
- [Warn, actionable] Sources/RuntimeMacOS/GuestShutdown.swift:41-45 — `note(.requestStop, …)` fires when `requestStop`
  throws because the guest stopped meanwhile (the plan's F-25 edge case, "treated as stopped"), so the plugin logs a
  benign race as "guest rejected the stop request". Fix: skip `note` when `machine.currentExit != nil` after the throw;
  add a test.
- [Suggest] Tests/RuntimeMacOSTests/HostProcessTests.swift — no tests for the plan's edge cases (empty input,
  `timeout: .zero`, a child that closes stdout early).

### Stage 1 — slice PH (spec)

Coverage 7/7 (C-120..C-126) plus the C-107 conversion of PH's 12 sites. Askpass environment identical to 12aa486;
SecurityResult, curl argv and exit-22 text identical; script goldens written first (7ac6bbb); 3567642 changed the
install script and updated both goldens in the same commit, deliberately.

- [Warn, actionable] Tests/RuntimeMacOSTests/GuestShellTests.swift — the recorded change "a signal death reports
  128 + signal" for the sync `run` has no assertion. Fix: a stub that kills itself with TERM, expect 143 and
  `timedOut == false`.
- [Suggest] HostProcess.swift (~110) via RestoreImages.swift:110 and GuestCredentials.swift:205 — children now get
  /dev/null as stdin (12aa486's curl inherited it), and a spawn failure reads `cannot run …`. Harmless; not in the
  recorded decisions. Fix: note it in the Status decisions.

### Stage 1 — test coverage (whole range)

- [High, actionable] Tests/RuntimeMacOSTests/HostProcessTests.swift:73-77
  (`testAChildThatIgnoresSIGTERMStillEnds`) — `trap '' TERM; exec sleep 30` with a 200 ms timeout asserts 137; if
  `sh` starts later than 200 ms under load, SIGTERM lands before the trap and the status is 143, so the test flakes.
  Fix: let the child print a readiness line after the trap and start the timeout after it, or assert `timedOut` and
  accept 137 or 143.
- [Warn, actionable] HostProcessTests.swift — no `timeout: .zero`, no empty `Data()` input, no closed-stdin race with
  pending input. Fix: add the three tests.
- [Warn, actionable] HostProcessTests.swift (cancellation test) — `task.cancel()` right after `Task {}` mostly exercises
  cancel-before-attach; cancel-while-running is never forced. Fix: cancel after the child signals it is up.
- [Warn, actionable] Tests/RuntimeMacOSTests/ExitLatchTests.swift:16-37 — "wait before finish" and "several waiters"
  call `finish` in a retry loop that usually finishes before the waiters register; no test races a timed wait with
  `finish`. Fix: register waiters first (Gate or arrival count), then `finish`.
- [Warn, actionable] Tests/ParbakeAgentTests/Support/AgentFixtures.swift:61-70 and GuestProcessTests.swift:11-41 —
  socketpair peers close only on the happy path; `HostPorts` has no cleanup. Fix: `deinit` closing every peer.
- [Warn, actionable] Tests/ParbakeAgentTests/SandboxServiceTests.swift:95-112 — `sleep 60` children outlive a failed
  assertion. Fix: `defer` kill.
- [Warn, actionable] Tests/ContainerRuntimeMacOSTests — no tests for two concurrent stops, KILL racing the stopping
  force stop, or shutdown before stop; the ladder `note` tests ignore the error payload (GuestShutdownTests.swift:84,95).
  Fix: add the interleavings and assert the payload.
- [Warn, deferred] Tests/RuntimeMacOSTests/GuestShellTests.swift:62-76 — upper wall-clock bounds (`< 5 s`, `< 8 s`,
  `< 10 s`) can still exceed on a loaded host after 8ac92f0. Question: keep the budgets, or drop the upper bounds and
  rely on `timedOut`/status plus `.timeLimit`?
- [Warn, actionable] ExitLatchTests.swift:41 — a 1 ms real-time wait; bounded and only asserts nil. (Low value; kept
  as reported.)
- [Suggest] GuestReachabilityTests.swift — zero-timeout and exact-deadline cases; GuestShellTests.swift:90-99 4 MB test
  duplicates HostProcess's large-output test.

### Stage 2 — performance

Pass. `HostProcess.run` blocks a dedicated thread, never the cooperative pool; the plugin's ssh request no longer pins a
pool thread for its whole run (12aa486 used `Task.detached` around a blocking run), and the actor stays answerable.
Synchronous environment closures on the actor (validate, clonefile, makeGuest) ran inline at 12aa486 too.

- [Suggest] Sources/RuntimeMacOS/ExitLatch.swift:52-70 — `wait(timeout:)` starts two unstructured tasks that nothing
  cancels; moved unchanged from 12aa486, bounded per call. Fix: a task group with `cancelAll()` on the first result.

### Stage 2 — security

Pass. Entitlements unchanged; no secret in the diff or fixtures; argv arrays, no shell, in HostProcess; shell
fragments are static constants; the install-script retry quotes its loop variable; `BundlePathPolicy` still runs in
`.live` and on the source bundle; the agent's `connect` seam defaults to vsock in the one production construction; the
force-unwrap fixes are not host-controlled (CWE-617 n/a); fds are not leaked to children (CWE-403); `security` keeps its
secret on stdin.

- [Suggest, deferred] Sources/RuntimeMacOS/GuestShell.swift:86-93 — CWE-526/CWE-214: the SSH password reaches ssh
  through an environment variable, as at 12aa486; exposure not wider. Question: is an fd- or keychain-backed askpass
  planned? No action in this diff.

### Stage 2 — architecture

Boundaries clean: `scripts/lint-boundaries.sh` exits 0; the agent imports neither RuntimeMacOS nor Virtualization;
AppKit only in Setup.swift; RuntimeService.swift imports neither Virtualization nor vmnet; the new test target's deps
respect ADR 0009. Seams each have a production conformer plus fakes; every RuntimeEnvironment closure is varied by a
test. No contradiction of ADR 0003, 0006 or 0009.

**SW-IO-05 verdict: justified with gaps.** Three options weighed honestly, the deviation is confined to two files
(HostProcess.swift:113, AgentCommand.swift:9), and the swap point is named. Gaps: no follow-up trigger, the runner
maintenance cost unstated, the `// legacy:` comments give no reason, and `AgentCommand` has no bound.

- [Warn, actionable] docs/adr/adr_0014_one_runner_and_one_error_type_per_module.md (Decision Outcome, Errors) — says
  `RuntimeFailure` is RuntimeMacOS's only `Error` type, but `ProbeError: Error` exists (GuestReachability.swift:2), used
  as the `reach` result payload. Fix: state the exception in ADR 0014, or make the payload a non-`Error` type.
- [Warn, actionable] ADR 0014 (Consequences) — the cost of the SW-IO-05 deviation is unstated: the project owns and must
  test a hand-written drain/timeout/SIGTERM-SIGKILL/cancellation runner until the swap. Fix: one Negative bullet.
- [Warn, actionable] Sources/parbake-agent/AgentCommand.swift:9-20 — drain-only, no timeout or cancellation, while ADR
  0014's driver says a child is "run, timed out and cancelled in one place". Fix: state in ADR 0014 that `AgentCommand`
  is drain-only and why that is safe for its two callers, or add a bound.
- [Warn, actionable] ADR 0014 (follow-up) — the swift-subprocess follow-up names no trigger; tools 6.2 is in use, so the
  rule's own legacy reason (tools floor) does not apply. Fix: name a trigger (the next change that touches
  `Package.resolved`, or the first HostProcess defect) and where it is tracked.
- [Warn, deferred] .claude/rules/swift-quality.md row 18 / ADR 0014 — the rule is a MUST whose only escape is a tools
  floor below 6.2; the project's reason is the hub-file policy. Question: accept a recorded project-level deviation, or
  add a second named legacy reason to the rule (via /hex-retro, never by editing the rule here)?
- [Suggest] HostProcess.swift:112, AgentCommand.swift:8 — `// legacy:` comments name the ADR, not the reason. Fix:
  `// legacy: Package.resolved is a hub file; see ADR 0014`.
- [Suggest] ADR 0014 — say the eight generic string cases of `RuntimeFailure` mirror ContainerizationError codes so call
  sites keep exact codes and text, and that narrowing them is not planned.

### Stage 2 — user-feedback (quality seat)

New texts verified lowercase, no trailing period, "cannot …"/"could not …" shape: "cannot start: container is already
starting", "the container was stopped while it started", "cannot run <path>: <reason>", the three "could not stop …"
log lines. Exit codes keep their mapping (guestStopped and internalError → 1, timeouts 75).

- [Warn, actionable] Sources/parbake/AgentSetup.swift:41-44 and Sources/parbake/AgentProbe.swift:92 — `GuestShutdown.run`
  without `note`, so a failed forced stop is dropped and `.forced` still yields "it was stopped forcibly and may need
  another boot". Fix: pass a `note` that prints "could not stop the guest forcibly: <error>" to stderr.
- [Warn, actionable] Sources/container-runtime-macos/RuntimeService.swift:508-510 — "guest did not shut down in time,
  stopping it" is now logged after the ladder already forced the stop (12aa486:504 logged it before `forceStop`).
  Orchestrator confirmed against 12aa486. Fix: reword to "…, stopped it forcibly", or log it before the forced step.
- [Warn, actionable] Sources/RuntimeMacOS/RuntimeFailure.swift:52-53 — the new `guestStopped` text names no next step,
  unlike its neighbours. Fix: append one (for example "; boot it again and check the guest's console") and update the
  goldens.
- [Warn, actionable] Sources/RuntimeMacOS/GuestReachability.swift:51 — "waiting for the guest was interrupted: \(error)"
  prints "CancellationError()". Fix: drop the cause for `CancellationError`, or use `causedMessage`.
- [Warn, deferred → merged into the PP seat's deferred finding] RuntimeService.swift:325-346, 495-512 — at 12aa486 a
  failed forced stop made `stop` fail; now the stop succeeds and only the log records it.
- [Suggest] GuestShutdown.swift `note` — the sibling callback is `onProbeError`; consider `onStepError`.
- [Suggest] Sources/parbake/Provision.swift:142 — same text as `ProvisionInputs.checkKey` (exit 64) but exit 1; the
  path is unreachable for `--authorized-key` in practice. Keep one validator.
- [Suggest] BundlePathPolicy.swift `try? destinationOfSymbolicLink` → message "links to , outside…"; and
  RuntimeEnvironment+Live.swift:73 `try? networkBootstrapInfos()` hides a decode cause.
- Dropped (pre-existing, out of scope): RuntimeService.swift:241,246 `try? await virtualMachine.forceStop()` in the
  readiness catch arms are at 12aa486:224,229 unchanged.

### Stage 1 — seams, behaviour preservation, stage 1 regression (spec)

Seams: every HostProcess, poll/waitForSSH, GuestShutdown and GuestCommands caller uses the shared helper with the
12aa486 durations (lock 2 s/30 s, agent dial 1 s, SSH 3 s, ladders 180/60 and 120/60). One `RuntimeFailure.exists`
case after three identical cherry-picks; the six merges carry no conflict-resolved hunks. Every new case has exit code
1; the nine stage 1 cases are untouched.

- [High, actionable] Sources/container-runtime-macos/RuntimeService.swift:145 — `environment.allocateNetwork` runs
  outside any conversion. Its DHCP failures (GuestDHCPServer.swift:42,54, `startFailure`/`watchFailure`) are now
  `RuntimeFailure.internalError`, so XPCServer's generic catch sends code `.unknown`, where 12aa486 sent
  `.internalError` with the same text (S-106 and C-146 break). GuestProvisioningTests.swift:590 converts by hand and
  misses it. Orchestrator confirmed the call site. Fix: wrap the call in `do { … } catch { throw
  RuntimeLifecycle.containerizationError(from: error) }` (or convert inside `.live`), plus a bootstrap route test whose
  fake `allocateNetwork` throws `startFailure` and expects `.internalError`.
- [Warn, actionable] Sources/parbake/ProvisionInputs.swift:24,79 — `ValidationError("\(error)")` now wraps a
  `RuntimeFailure`, so the exit-64 text loses the `invalidArgument: "…"` shape a ContainerizationError printed at
  12aa486; no recorded decision covers it and no test pins it. Same drift in diagnostic prints at StateProbe.swift:109,114,
  AgentProbe.swift:135, Setup.swift:36. Fix: record the bare text as a decision (it reads better), or restore the old
  shape; pin it in a test either way.
- [Warn, actionable] (duplicate, merged) "allocated guest address" logged twice — same as the PP seat's finding.
- [Warn, actionable] Tests/RuntimeMacOSTests/RuntimeMacOSErrorTextTests.swift (private constructors after "The
  constructions below repeat the text…") and RuntimeFailureGoldenTests.swift (`forwarded(_:at:)`) — these rows build the
  error inside the test, so they pin the test's own copy, not the production site (texts do match 12aa486). Fix: drive
  the real site where possible (incompatible-overlay and agent-not-ready via the fake environment, GuestAgent
  processNotStarted), else label the rows as text pins.
- [Suggest] Sources/parbake/Provision.swift:164 — 5 s → 3 s poll (decided in Q9; record in Status for completeness).
- [Suggest] Sources/RuntimeMacOS/GuestReachability.swift:62 — a cancelled wait now throws
  `RuntimeFailure.interrupted("…: CancellationError()")` instead of `CancellationError` (merges with the user-feedback
  Warn on the same line).

Stage 1 regression spot-check: **F-01 holds, F-02 holds, F-03 holds, F-04 holds, F-05 holds, F-06 holds, C-020
bundle-path policy holds** (validated once in bootstrap via `.live`, inside the conversion; all six reason texts
byte-identical; tests cover every reason).

Behaviour preservation (parity table, 12aa486 → HEAD, about 60 sites: BundlePathError ×12, ContainerizationError ×45,
IncompatibleOverlayError, VersionMismatch, ProcessLost, ParbakeError and ValidationError sites): text and code identical
everywhere except (a) recorded decisions (guestStopped text, `cause:` suffix, spawn-failure text, 128 + signal,
publicKey exit 64 → 1, AgentProbe's wait ending on guest exit), (b) the DHCP `.internalError` → `.unknown` drift (High
above), (c) the ValidationError wrapper text (Warn above), (d) a benign improvement: an `IncompatibleOverlay` reaching
the plugin outside the bootstrap catch now maps to `.invalidState` instead of `.unknown`.

### Stage 2 — documentation (doc-reviewer; Medium → Warn)

Docs-quality: ADR 0014 clean under `prose.py` and `doc_declaration.py`; other prose hits are on lines the diff did not
touch. No plan IDs or SHAs in added comments. The end-to-end checklist carries no dates, hosts, user names or commits.
ADR 0003 floors match `stopGuest`. Specs unchanged and still accurate.

- [Warn, actionable] README.md:276 and CHANGELOG.md:23 — "stopping a container while its guest boots force-stops the
  VM" holds only until the VM boot returns; during the agent-readiness wait a stop takes the `.running` path (graceful
  ladder, then — because of the High at RuntimeService.swift:250 — a forced stop when readiness returns). Fix: say
  "while the VM starts, before the agent wait", and that a stop during the agent wait is an ordinary stop (after the
  High is fixed).
- [Warn, actionable] docs/adr/adr_0014_one_runner_and_one_error_type_per_module.md (Poll interval, ~190-193) — "one
  default of 3 s" holds only for `waitForSSH`; the agent dial keeps 1 s and the lock retry 2 s. Fix: say so.
- [Warn, actionable] Sources/RuntimeMacOS/GuestShell.swift:136 — doc comment says "as it always did" (history). Fix:
  "A timeout reports -1, so callers need not know the signal that ended ssh."
- [Warn, actionable] ADR 0014 Implementation and Validation checklists (~232-242) — all boxes unchecked although the ADR
  is Accepted and the three validation claims hold. Fix: tick them, as ADR 0003 does.

### Stage 2 — pitfalls (researcher)

Mitigated: terminationHandler vs pipe reads (exit awaited, readers joined); SIGPIPE (`F_SETNOSIGPIPE`); `Process.run()`
throwing (no thread started, pipes released); fd inheritance; SIGTERM-only `terminate()` (SIGKILL after 2 s); 128 +
signal only for `.uncaughtSignal`; ExitLatch resume-once outside the lock; `HostProcess.run` never blocks the pool;
RuntimeService re-reads state after every await, the ssh `Task {}` is stored and cancelled.

- [Warn, actionable] Sources/RuntimeMacOS/ExitLatch.swift:65-68 — `wait(timeout:)` starts two unstructured tasks and
  cancels neither (SW-CONC-13): the sleeper outlives an exit, the waiter outlives a timeout, and a cancelled caller is
  not woken. Moved unchanged from 12aa486 into a new file (the performance seat rated it Suggest; max-wins → Warn). Fix:
  race them in a task group and `cancelAll()` after the first result.
- [Warn, actionable] Sources/RuntimeMacOS/GuestReachability.swift:25-26 — `sleep(every)` is not clamped to the time
  left, so `poll` overshoots its deadline by up to `every`; an in-flight `reach` is bounded only by the shell's own
  timeout. Fix: sleep `min(every, deadline - now())`; give `reach` a timeout where the poll deadline should bind.
- [Warn, actionable] Sources/RuntimeMacOS/HostProcess.swift:163,188,193 vs ContinuousClock elsewhere — child timeouts and
  the SIGKILL grace run on `DispatchTime` (awake time), while poll and shutdown deadlines run on ContinuousClock; after a
  host sleep they diverge. Fix: document "child timeouts are awake time" at the `timeout:` parameter, or use one base.
- [Suggest] HostProcess.swift:99,194 — a late `Cancellation.cancel()` can `terminate()` an exited child; the grace
  closure checks `isRunning` then signals a pid (CWE-367, nanosecond window). Fix: clear the process under the lock
  when `execute` ends.
- Dropped as stated convention: HostProcess.swift:169 grandchild holding the pipes keeps `threads.wait()` from
  returning — that is F-37, deferred by the plan (Edge cases).
- Dropped as pre-existing: Sources/parbake-agent/GuestProcess.swift:56,73-75,118-119 fd leaks when a vsock `connect`
  throws — the production connect could already throw at 12aa486; the seam does not widen it.
