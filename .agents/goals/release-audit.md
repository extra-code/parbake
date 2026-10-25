# Goal: "Parbake release audit"

Source: .agents/discussions/release-audit.md · Written: 2026-10-22 by /hex-loop

## Definition of done

- [x] "S1.1 /hex-review max of the tree: high+ findings fixed or ADR'd" — evidence: stage 1 review .agents/research/research_release_audit_stage1_review.md traced 28 fixed + D-02 deviation (ADR 0011); H-08/H-12 and F-01..F-06 fixed per spec check (979e1ca, 806f974, f346b73, d6767a2).
- [x] "S1.2 module-boundary ADR or stays-as-is" — evidence: docs/adr/adr_0009_module_boundaries_and_one_version_target.md (Proposed; code changes carried into the stage 1 plan).
- [x] "S1.3 every C-n done or deferred; agent Status true; --config documented" — evidence: 5b66939 (specs, agent Status, README --config table), d6767a2.
- [x] "S1.4 XPC bundle path canonical, root-checked, tested" — evidence: BundlePathPolicy and bootstrap wiring, 24d019b, 04599bf; checklist step 15 passed.
- [x] "S1.5 CODESIGN_IDENTITY, gated keychain ACL, ADR on 0004 re-measure" — evidence: CODESIGN_IDENTITY 9066ba0 and PARBAKE_CODESIGN_IDENTITY f346b73; identity-gated ACL 03a1dc3; ADR 0010 Accepted (54087a3).
- [x] "S1.6 SECURITY.md, linked from README" — evidence: SECURITY.md linked from README, 5b66939, d6767a2.
- [x] "S1.7 README boundaries" — evidence: README boundaries, 5b66939, d6767a2.
- [x] "S1.8 one version source, skew warning, CHANGELOG v0.1.0" — evidence: ParbakeVersion + 0.0.0-dev stamp per ADR 0012 (a48030d, 88e2bd1, 5723ef5, a8f0fee); skew warning 04599bf; CHANGELOG v0.1.0 5b66939; stamped 0.1.0 dry-run build verified both CLIs and agent line.
- [x] "S1.9 seven actionable errors, os_log subsystem" — evidence: RuntimeFailure, os_log subsystem, exit codes: ff773e4, 04599bf, e21dca1, 979e1ca.
- [x] "S1.10 e2e checklist run, with only generalized findings recorded publicly" — evidence: docs/end_to_end_checklist.md run on the stamped 0.1.0 release candidate, 23c4742 and 694401f: 19 of 20 steps pass; the step 15 boot from a removable volume was skipped because a macOS removable-volume access prompt cannot be answered unattended.
- [x] "S1.11 v0.1.0 tag command proposed" — evidence: proposed in the stage 1 plan: `git tag -s v0.1.0 -m "Parbake 0.1.0" <release commit>` (not run).
- [x] "S2.1 VM-free plugin and agent tests, pure-logic tests" — evidence: agent 6e2705c, 68a7027; plugin routes without a VM e2e9e85, fe76f8a, adcb7f3, 1e7209f; pure logic 7ac6bbb, be3a6f0, 7dbb9f2.
- [x] "S2.2 task coverage per module" — evidence: task coverage f8e1550, 56513f5; per-module line coverage recorded in the stage 2 plan at 694401f (total 52.4%).
- [x] "S2.3 listed duplication removed" — evidence: shared helpers 261af94..f0fa75d; call sites 47bc372, 7755f4d, 102d56d, 4f21c8c, 5bfe78c, ff072b0, 1e7209f; ADR 0014 a6f4db4 (Foundation.Process kept, deviation from SW-IO-05 recorded).
- [x] "S2.4 three force unwraps removed" — evidence: ff072b0 (GuestProcess), 7755f4d (DHCPLeases).
- [ ] PR merge-ready (DONE block only) — evidence: the PR URL, and the
  PR is not a draft.
- [ ] CI green per job (DONE block only) — evidence: every check run on
  the PR head SHA with its conclusion; every skipped job states its
  skip reason (its `if:` or path filter).
  A skip with no reason is not green.
- [ ] Deep verify passed (DONE block only) — evidence: the full documented verification result.

## Autonomy

- Prompting: never — no question waits for a human; a doubt runs
  § Issue resolution.
- Granted acts (authority: the pasted prompt): none
- Forbidden or narrowed acts: None.

## Issue resolution

Every doubt — an ambiguous requirement, a design question, a failure
with an unclear cause — runs this protocol:

1. Delegate the research to a sub-orchestrator.
2. Record question → research → decision in this file or in the PR.
3. Defer to a GitHub issue only in hard cases — the research ends with no
   decision, or the decision needs an act outside the grants; the issue
   link is the recorded decision.
4. Every doubt not deferred ends in an action.
5. A pre-existing failure that blocks done is in scope and runs this
   protocol.
6. Findings outside this goal's scope become follow-up issues.
7. Secrets and credential-bearing logs are never written to any committed
   file, commit message, PR text, PR comment or review comment, or issue.
   Security findings are never filed as issues:
   this file records them by reference only — location and class, no
   secret value or exploit detail — and only the DONE block reports them
   in full.

## Loop shape

- Entry point: Run the /hex-plan skill on "Parbake release audit, per .agents/discussions/release-audit.md".
- Refinement rounds: 2 — counts outer cycles: each review ⇄ execute
  pass is one, and so is every failed repair or retry cycle — a red
  gate's fix pass, an execute or finalize retry, a post-finalize CI fix ⇄
  re-finalize pass. Inner review-fix rounds do not count, and their limit
  is untouched.
  Past `2`, the DONE block reports every remaining criterion `not met`
  and the run stops.
- Ticks: /hex-loop commits nothing. The session creates or switches to
  the branch the pasted prompt's I9 names and commits this file first on
  it. A box is ticked only between hex-mode runs, never during one, and
  each tick is committed at once; every tick lands before the final
  /hex-finalize, none after it. The `(DONE block only)` criteria are
  evidenced only in the closing DONE block, never ticked.

## Rules

- Run rules: None.

## Emphasis

None.

## Context

- Source: [.agents/discussions/release-audit.md](../discussions/release-audit.md) — "Parbake release audit", ratified → loop on 2026-10-22; its Requirements, Decisions, Open questions and Verification are the spec of this run.
- Research: `.agents/research/research_release_audit_codebase_recon.md`, `.agents/research/research_release_readiness_bar.md`, `.agents/research/research_release_audit_council.md`, `.agents/research/research_release_audit_archaeology.md`, `.agents/research/research_release_audit_field_pitfalls.md`.
- Related: `docs/specs/`, `docs/adr/`, `.agents/plans/plan_macos_runtime.md`, `AGENTS.md`, `scripts/dev-env.sh`, `Taskfile.yml`, `.github/workflows/ci.yml`.

## Decisions log

- Order (2026-10-22): question: plan first per Start, or review first? → research: S1.1's review findings and S1.2's ADR feed the plan's contracts → decision: run `/hex-review max` (audit/empty → audit/all, helper branches allowed by the discussion) and `/hex-architect` first, then `/hex-plan` on the discussion plus both outputs.
- Helper branches (2026-10-22): audit/empty and audit/all deleted after the S1.1 review, per the discussion's recommended answer.
- Signing identity (2026-10-22): use `TeamIdentifier` from `codesign -dv`, not an identifier inferred from the certificate name. Specific certificate and team identifiers are omitted.
- Stage 1 scope (2026-10-22): the S1.1 review (.agents/research/research_release_audit_full_review.md) found 4 Block and 25 High, plus 2 deferred High. All of them go into the stage 1 plan next to requirements 3–11 and ADR 0009's code changes.
- Outer cycle 1 (2026-10-22): the closing stage 1 review (.agents/research/research_release_audit_stage1_review.md) returned Request Changes, with 2 Block, 4 High, and H-08/H-12 still open → decision: run /hex-execute on the appended pipelines R1 (code) and R2 (docs, host-run limits). The ADR 0010 email is redacted in R2, because a personal address should not be published in a doc. Accepting ADR 0009 stays the user's call.
- ADRs 0012/0013 (2026-10-23): the user accepted ADR 0009 and added ADRs 0012 (release tag is the version source) and 0013 (tagged releases, git-cliff notes) → research: a consistency check against the repo found that 0012/0013 have no implementation yet, that 0009 is marked both superseded and rewritten, that CI signing identity is unspecified, and that checklist step 13, CHANGELOG and spec C-005 still assume the 0.1.0 constant → decision: S1.8 now means ADR 0012/0013 implemented. R1/R2 are resumed with that scope plus the doc fixes. Protected tag rules and the remote stay with the user.
- Finalize timing (2026-10-23): question: finalize stage 1 now or once at the end? → research: the goal allows one PR per repo, and stage 2 builds on the same branch → decision: one /hex-finalize after stage 2. S1.10 stays open until the end-to-end checklist passes again on the release commit after stage 2, as the discussion requires.
- Stage 2 review and stop (superseded by Resume below) (2026-10-24): question: fix the stage 2 review's open High now, or stop? → research: the /hex-review xhigh over bcef49a..deeff1f found 0 Block, 1 High and 15 Warn (7 actionable). The High is C-142, partial: a failed force stop during `.starting` leaves state behind. C-144 is partial: the rejected-stop log line. Both are recorded as plan row PR in .agents/plans/plan_release_audit_stage2.md. The worker hit the account's weekly limit (resets 2026-10-26 23:00) before writing its report file, so no sub-orchestrator can run until then → decision: defer row PR as the run's one open follow-up, and skip /hex-finalize: no remote exists, so it can neither push nor open the PR. The run ends with DONE. The remaining unmet criteria need a remote, which is the human's step. A follow-up issue cannot be filed without a remote, so the follow-up lives in the plan.
- Resume (2026-10-24): the user loaded the signing key and lifted the usage limit → decision: the stop decision above is revoked. Run row PR (C-142, C-144) as outer cycle 2 of 2, verified by one spec-reviewer worker. A fourth /hex-review would exceed I5's cap of 3, so the 15 lost Warn findings stay a follow-up. Then /hex-finalize, local acts only, since no remote exists.
- Finalize (2026-10-24): row PR is closed (9214eae: C-142 and C-144 met per the spec check; `task clean check` exits 0). /hex-finalize then halted at pre-flight (6)(i): the repository has no remote, so there is no fetched target to rebase onto, and the local `main` is not a fallback. Nothing was rewritten and no backup ref was armed. PR merge-ready, CI green and Deep verify cannot progress without a remote, which is a human step. The 15 lost Warn findings from the stage 2 review stay a follow-up (I5 review cap reached).
