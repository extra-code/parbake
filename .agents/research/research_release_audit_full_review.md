# Research: Parbake full-repo review (release audit, stage 1 item 1)

## Metadata

**Date:** 2026-10-22
**Domain:** review
**Triggered by:** `.agents/goals/release-audit.md` › stage 1 item 1, `/hex-review --tier=max audit/empty..audit/all`
**Expires:** when `main` moves past `85aa21a`

## Code Review: audit/empty..audit/all (tree of `main` at 85aa21a)

### Summary

- **Verdict: Request Changes.** Four Block findings come from the doc-accuracy mapping. There is one security High, and five systemic causes each touch three or more findings.
- Tier: max (explicit `--tier=max`) · Baseline: `audit/empty` · Diff: 95 files, +11569 / -0, 4 code areas (RuntimeMacOS, plugin, parbake, parbake-agent) plus docs, build and CI.
- Overlays: breadth=adversarial, rca=on (every finding above Suggest).
- **Cross-model: skipped.** `hex.md › Preferences` pins no adversary and no second harness is on `PATH`. One review layer is missing.
- Gate evidence: `task check` on the identical working tree exited 0. It ran 56 tests in 19 suites plus 6 tests in 1 suite, and printed 7 swift-format warnings (`NeverForceUnwrap` at `DHCPLeases.swift:30`, `GuestProcess.swift:223` and `:506`, plus `forEach` and line-break style warnings).
- Counts after dedupe: **Block 4 · High 25 · Warn 62 · Suggest 17**, plus 21 deferred items (2 High, 12 Warn, 7 Suggest).
- Architect: dependency direction is clean. No boundary violation was found. The concern is the fork pin (H-04), and the ADR text that drifted (W-40).
- SOTA: the core choices are current or ahead of comparable tools. Two examples: a fresh machine identifier per clone, and an ASIF overlay per container. The gaps are in operability and hardening.

### Run record

| Phase | Seats (all `standard` = sonnet) | Notes |
|---|---|---|
| 1 Discover | inline | Read AGENTS.md, hex.md, recon, discussion. Ran `task check` as gate evidence. |
| 2 Stage 1 | spec (post-implementation), quality (test coverage) | Spec coverage was 34/38 IDs (30 spec C-/V-n plus 8 ADRs). Partial: guest_agent C-002 and C-003, bundle_rebuild C-004, ADR 0003 kill path. |
| 3 Stage 2 | user-feedback, security, performance, doc-reviewer, architect, researcher (competitive), researcher (pitfalls) | The security seat also covers the `perspectives.always` rules. Stage 2 launched as Stage 1's last seat ran, within the 8-worker cap. The stages are independent, so nothing depended on that order. |
| 3 Simulators | first-time, power-user, adversarial, automation | Design mode, not artifact mode. Artifact mode needs a scratch worktree with its own fork build from `scripts/dev-env.sh build`. Booting also needs a VM bundle and stopping the installed services. Simulators walked the docs against the source and ran only `parbake --help` and validation-time errors. |
| 4 RCA | inline | 8 clusters, below. |
| 5 Cross-model | — | skipped: none configured. |

**Orchestrator decisions:**

- **Dropped as false (2):**
  - The researcher's "password in argv" claim on `GuestCredentials.swift:44-47`. `security` runs with `["-i"]`, and the command reaches it on stdin (lines 105, 113-114).
  - The architect's claim that the test suites cited in the ADRs do not exist. `DHCPMessageTests`, `GuestCredentialsTests` and `GuestPreparationTests` are suites inside `GuestProvisioningTests.swift`, at lines 87, 143 and 185.
- **Dropped as settled out of scope:** SSH host keys, restore-image checksums, ad-hoc signing and notarization, the keychain `-A` ACL as such, and guest-agent file copy (C-007).
- **Doc grade mapping per severity.md:** Critical → High, Medium → Warn, Accuracy → Block. One Accuracy item (README `[guest] agent` key) is an omission, not a false claim. It is merged into H-22 at High.
- **Severity:** duplicates resolve max-wins, for example the `ValidationError` exit code: Warn from user-feedback, High from automation, so High.
- **Verified:** the orchestrator re-read the code for every High below except the doc-only ones. Simulator claims marked *unverified* by their seat stay Suggest.
- **Out of scope:** the untracked `docs/adr/adr_0009_module_boundaries_and_one_version_target.md` is outside `audit/all` and was not reviewed.

---

## Findings

Format: **ID [severity] file:line**, then the issue, its root cause (the RCA cluster in brackets) and the suggested fix. Security items name the location and the weakness class only.

### Block

- **B-01 [Block] README.md:104-107.** It says `create` runs `agent install`, `agent-probe` and `state-probe`. `Create.swift:174-203` runs only install, provision or setup, and scripts.
  - Root cause: the docs are not checked against the code [R6].
  - Fix: list the chained commands separately from the standalone ones.
- **B-02 [Block] AGENTS.md:19-20.** It says "ad-hoc signs both executables". `Taskfile.yml:46-48` signs three: the plugin and parbake with the entitlement, and parbake-agent without it.
  - Root cause: [R6].
  - Fix: name all three and say which ones get the entitlement.
- **B-03 [Block] docs/architecture.md:28-30.** It says `create` builds in four steps, ending with "shut down through the agent". Without `--username`, `create` opens Setup Assistant instead (`Create.swift:195-203`).
  - Root cause: [R6].
  - Fix: describe both branches, or say "with `--username`".
- **B-04 [Block] docs/specs/spec_guest_agent.md (C-005 Routes).** It lists `closeStdin` and `delete` as runtime XPC routes. No such routes exist (`RuntimeMacOSHelper+Start.swift:56-70`). Stdin closes when the vsock connection closes, and `DeleteProcess` is called internally.
  - Root cause: [R7].
  - Fix: reword C-005 to the real mapping.
  - Grade: the spec seat graded this Warn. It is an Accuracy-class defect, a doc wrong about shipped behaviour, so it is raised to Block.

### High

**Correctness, data and runtime**

- **H-01 [High] Sources/RuntimeMacOS/MacOSVMBundle.swift:181-186, 233-240, 252-272, 116-123; Sources/container-runtime-macos/RuntimeService.swift:117-122.** A half-built instance boots the shared base read-write.
  - What happens: `instance(at:)` and `resetOverlay` create the `Disk.img` symlink before the overlay, with no cleanup on failure. `MacOSVMBundle(url:)` checks only that the four files exist. The next `bootstrap` reuses `vm/`, and `storageDeviceAttachment()` opens the base `Disk.img` with `readOnly: false`. For a layer instance it opens the shared `Layer.asif` read-write.
  - Raised by three seats: performance, pitfalls and the adversarial simulator.
  - Root cause: non-atomic filesystem transitions, and a validity check that tests existence only [R3].
  - Fix: build in `vm.parbake-new` and rename, or remove the destination in a `catch`. Make an instance whose `Disk.img` is a symlink invalid without `Overlay.asif`.
- **H-02 [High] Sources/parbake-agent/main.swift:13-46** (writes at `GuestProcess.swift:223` and `VsockFront.swift:112`). The root agent never ignores SIGPIPE. Only `RuntimeMacOSHelper+Start.swift:38` does.
  - Effect: a write to a closed child stdin, unix socket or vsock kills the daemon and every running guest process. `parbake` is exposed the same way (`GuestAgent.swift:333`, `:364`, and `GuestShell.swift:95`).
  - Raised by: performance and pitfalls.
  - Root cause: process hardening is done per entry point, not shared [R2].
  - Fix: call `signal(SIGPIPE, SIG_IGN)` at the start of the agent and of `parbake`. Children are already reset through `POSIX_SPAWN_SETSIGDEF`.
- **H-03 [High] Sources/RuntimeMacOS/GuestShell.swift:36-41, 95-103; Sources/container-runtime-macos/RuntimeService.swift:473-520.** `shutDownOverSSH` runs a synchronous ssh `Process` on the `RuntimeService` actor.
  - Missing bounds: there is no overall deadline, no `ServerAliveInterval`, and the child is never killed.
  - Effect: a hung session blocks every XPC route (`state`, `wait`, `kill`, `stop`), and the stop timeout is never enforced.
  - Raised by: performance, pitfalls and architect.
  - Root cause: blocking subprocess I/O with no deadline [R2].
  - Fix: give `GuestShell.run` a timeout that terminates the process, add `ServerAliveInterval` and `ServerAliveCountMax`, and run the call off the actor, bounded by the stop timeout.
- **H-04 [High] Package.swift; Package.resolved; AGENTS.md › Architecture rules; README.md:28-29.** The pinned fork revision (`804209b1` plus only `3b9b5b75`) lacks fork commit `0f824548`. That commit makes the exit and shutdown handler read the runtime configuration when no `config.json` exists (`ContainersService.swift` around lines 1005 and 1134), and this plugin writes no `config.json`. CI only compiles, so it cannot catch this. Commit `13ff2d85`, a warning log, is also missing.
  - Root cause: the pin was set at one commit, not the branch tip [R6].
  - Fix: pin the `parbake` branch tip in `Package.swift`, and update AGENTS.md, README and CONTRIBUTING.
- **H-05 [High] Sources/RuntimeMacOS/MacOSVirtualMachine.swift:142-146, 153.** Error code 6 is always reported as "stop one first".
  - Effect: in the known leaked-slot case (field-pitfalls note), that advice cannot work. `start(options:)`, used by `provision`, `create` and `install`, does not map the error at all.
  - Root cause: missing error taxonomy [R5].
  - Fix: one shared mapping. Add the possible-leaked-slot and host-reboot hint when fewer than two guests are live, and never retry in a loop.
- **H-06 [High] Sources/container-runtime-macos/RuntimeService.swift:262, 287-289.** `kill -s KILL` is refused while a `stop` is in progress, because state is `.stopping`. So there is no way to escalate when a stop hangs, though README says KILL "stops it at once".
  - Root cause: an actor state machine with no defined transitions during awaits [R4].
  - Fix: accept `.stopping` for SIGKILL and force-stop the VM.
- **H-07 [High] Sources/container-runtime-macos/RuntimeService.swift:333-343, 39.** `processExit` waits only 5 s (`guestLossTimeout`) for the guest to stop.
  - Effect: a job that reboots or shuts the guest down usually takes longer. `exec` then exits 1 with a raw `ProcessLost` error while the container still reads `running`. ADR 0008's failure table takes that as the job's own exit code.
  - Root cause: [R5].
  - Fix: wait for the stop as long as a shutdown takes, or give the lost-process error its own wording and a documented row in ADR 0008.
- **H-08 [High] Sources/parbake/Create.swift:141, 190-207; Sources/parbake/Provision.swift:62-90; Sources/RuntimeMacOS/RestoreImages.swift:139-141.** Most `create` input is validated only after the multi-GB download and install. Any failure then deletes the installed bundle.
  - Inputs affected: username, key files, `--sudo`, `--agent`, keychain, stdin password, `--script`.
  - Raised by all four simulators.
  - Root cause: [R3], plus validation that runs in the sub-command, not up front.
  - Fix: run every `Provision` and `GuestScript` check in `Create.run` before `Install`, and check keychain access early.
- **H-09 [High] Sources/parbake/Create.swift:141; Sources/RuntimeMacOS/RestoreImages.swift:96, 140, 147.** Two `create` runs on one path both pass the exists check. They resume into one cache file with no lock, and one run's catch deletes the other's bundle or `.parbake-new`.
  - Root cause: no lock discipline [R3].
  - Fix: take an flock on the cache file and the target. Do not remove the target when the failure was "already exists".
- **H-10 [High] Sources/parbake-agent/GuestProcess.swift:313-330.** spec_guest_agent C-002 requires `FAILED_PRECONDITION` for an account with no GUI session. No such check exists, so the launch fails some other way through `launchctl asuser`.
  - Root cause: a spec clause with no test or implementation [R7].
  - Fix: probe `launchctl print gui/<uid>` and throw `failedPrecondition`, or amend C-002.
- **H-11 [High] Sources/container-runtime-macos/RuntimeService.swift:84-160; README.md:153-166.** Several `container run` inputs are silently ignored:
  - `-v`/`--mount` and `-p`/`--publish`;
  - the run command after the image;
  - run-level `--env`, `--workdir` and `--user`.

  README › Limitations does not list them.
  - Root cause: [R6].
  - Fix: refuse unsupported mounts and ports in `bootstrap` with a clear error, and list them in Limitations. See deferred D-10.
- **H-12 [High] Sources/parbake/\*.swift (35 `ValidationError` sites, for example Provision.swift:169, GuestScript.swift:25, AgentSetup.swift:48).** Runtime failures exit 64 with the usage block. That covers SSH timeout, script exit N, guest not shut down and ssh-keygen failure. CI cannot tell a timeout or script failure from a usage error, and the script's own exit code is lost.
  - Grade: user-feedback Warn, automation High; resolved max-wins.
  - Root cause: [R5].
  - Fix: a `ParbakeError` with `ExitCode` mapping, and a documented exit-code table.

**Security**

- **H-13 [High] Sources/RuntimeMacOS/GuestShell.swift:78; Sources/RuntimeMacOS/MacOSVMBundle.swift:81-87.** CWE-88 / CWE-78. The ssh destination is built from a username read back from the bundle's `Provisioned` file, with no validation on read and no option terminator. The strict check exists only on write (`Provision.swift:66`).
  - Root cause: input is validated at the CLI, not at each use site [R1].
  - Fix: validate `provisionedUsername` with full-match `\A[a-z_][a-z0-9_-]{0,30}\z`, pass `-l <user> -- <host>`, and validate the address as IPv4.
  - Ship together with D-01.

**Tests**

- **H-14 [High] Tests/RuntimeMacOSTests/GuestProvisioningTests.swift:143-183; Sources/RuntimeMacOS/GuestPreparation.swift:42-56; Sources/RuntimeMacOS/GuestAgentInstallation.swift:58-60.** The generated root scripts are tested only for syntax (`bash -n`). There are no tests with a heredoc delimiter or a line break in a key, password or username. In code, the password is not checked for the `PARBAKE_` delimiters; keys are (`Provision.swift:136`). CWE-74, location only.
  - Root cause: [R1], [R8].
  - Fix: reject delimiter-bearing and control-character input in one validator. Add hostile-input tests that run the user half of the script with `sudo` stubbed.
- **H-15 [High] Tests/RuntimeMacOSTests/GuestProvisioningTests.swift:185-290 (`DHCPMessage.parse`, Sources/RuntimeMacOS/DHCPMessage.swift:54-113).** The parser of guest-controlled frames has thin negative tests. Missing cases:
  - option overrun;
  - missing magic cookie;
  - bad op, htype or hlen;
  - IHL other than 5;
  - option 53 with a length other than 1;
  - missing end marker.

  The code was verified bounds-checked; the tests do not pin that.
  - Root cause: [R8].
  - Fix: a parameterized mutate-and-truncate test that expects nil.

**Documentation and onboarding**

- **H-16 [High] README.md:24-30 (Requirements).** README never says how to get the fork's `container` build, and never links CONTRIBUTING.md. It also never says that the installed `container` must be the fork's build; a stock release is unsupported.
  - Root cause: [R6].
  - Fix: add the fork, its tag and the build command, or a link, and state that the fork's build is required.
- **H-17 [High] README.md:120-137 (Build and install / Run).** The README lacks:
  - a command for "restart the container system services";
  - the sudo and ownership needs of `INSTALL_ROOT=/usr/local`, and the default debug build;
  - any `exec`, `stop` or `rm` example, or a mention of the dev CLI path after `dev-env.sh up`.
  - Root cause: [R6].
  - Fix: add the commands and a `--name` example.
- **H-18 [High] README.md (missing section).** There is no recipe for removing stale state:
  - containers and their overlays;
  - `~/.container-macos-dev`;
  - the bundle and the `.parbake-new` / `.parbake-old` leftovers;
  - the restore-image cache;
  - the keychain item;
  - the plugin itself (`task uninstall`).

  Raised by three simulators. This is also audit requirement 7.
  - Root cause: [R6].
  - Fix: add a "Remove everything / CI host cleanup" section.
- **H-19 [High] Sources/RuntimeMacOS/GuestAgentInstallation.swift:7, 9 → README.** The agent binary path, the agent log `/var/log/parbake-agent.log` and the plugin log location appear in no doc.
  - Root cause: [R6].
  - Fix: add a "Logs and troubleshooting" section.
- **H-20 [High] scripts/dev-env.sh:25-33, 141-160 → README.** These parts of the script are undocumented:
  - the commands `build`, `status`, `logs` and `container ARGS`;
  - the flags `up --no-build -y`;
  - the variables `CONTAINER_SRC`, `DEV_APP_ROOT`, `DEV_LOG_ROOT` and `INSTALLED_CONTAINER`.
  - Root cause: [R6].
  - Fix: list them, or point to `dev-env.sh help`.
- **H-21 [High] Sources/parbake/Create.swift:53-89; Sources/parbake/BundleConfiguration.swift:40-86 → README.** README does not cover:
  - the `create` options `--cpus`, `--memory`, `--cache-dir`, `--full-name`, `--keychain-service`, `--agent`, `--no-setup` and `--version`;
  - the `--config` keys, including `[guest] agent`.
  - Root cause: [R6].
  - Fix: add a keys table, and name the options.
- **H-22 [High] Sources/parbake/Install.swift, Provision.swift, Setup.swift, Layer.swift:36-42 → README.** The flags of the standalone commands are not described. For `layer`: `--cpus`, `--memory`, `--timeout` and `--replace`.
  - Root cause: [R6].
  - Fix: one line per command, plus the `layer` options.
- **H-23 [High] repo root.** There is no `CHANGELOG.md` and no `SECURITY.md`. These are known audit items 6 and 8; they are listed for completeness.
  - Fix: add both.
- **H-24 [High] Sources/RuntimeMacOS/GuestCredentials.swift:135-139; Sources/parbake/AgentSetup.swift:57-59.** A locked or refusing keychain yields raw `security` stderr with no hint, and only after the install (see H-08).
  - Root cause: [R5].
  - Fix: map the "interaction not allowed" and "auth failed" statuses to "unlock the login keychain / run from a GUI session", and check before the install.
- **H-25 [High] Tests/RuntimeMacOSTests/GuestProvisioningTests.swift:98, 115; Tests/RuntimeMacOSTests/OtherVolumeTests.swift:9-61; Tests/RuntimeMacOSTests/MacOSVMBundleTests.swift:41-292.** These tests need the real login keychain, `hdiutil` with HFS+, and ASIF/VZ. They declare no `.enabled(if:)` or tag, so they fail rather than skip on a host without them.
  - Grade: Warn ×3 from the test seat; raised to High as a cluster because CI correctness depends on the runner's keychain state.
  - Root cause: [R8].
  - Fix: tag the tests, gate them by trait, and declare the host requirements in AGENTS.md.

### Warn

**Process, I/O and concurrency [R2], [R4]**

- **W-01 GuestShell.swift:95, GuestCredentials.swift:114.** `FileHandle.write(_:)` cannot be caught. stdin is written before stdout is drained, so an early ssh exit means EPIPE, and a large output means a deadlock. Fix: `try write(contentsOf:)` on its own thread after the readers start.
- **W-02 GuestShell.swift:36-42, 81-83.** Ambient `~/.ssh/config` and the full environment are inherited, so agent forwarding, ControlMaster and ProxyCommand apply (CWE-522). ControlPersist can hold the pipes open. Fix: `-F /dev/null`, `ForwardAgent=no`, `ClearAllForwardings=yes`, `ControlMaster=no`, `ControlPath=none`, `IdentityAgent=none`, and a minimal environment.
- **W-03 GuestShell.swift:42, 68-70.** The password travels in the ssh environment (CWE-214), readable by same-uid processes. Fix: an fd- or file-based askpass. See D-04.
- **W-04 RuntimeService.swift:178-186, 264-269, 347-352; :85/124/158.** Actor reentrancy:
  - a stop during boot is overwritten by `.running`;
  - a second start can double-start;
  - a shutdown during boot releases the network;
  - a second stop returns early;
  - a throw leaves `.stopping`.

  Fix: add `.starting`, re-check after each await, and test the state machine.
- **W-05 GuestAgent.swift:274-289.** `connected()` reentrancy means a double dial and a leaked Vminitd and fd. Fix: share one in-flight `Task`.
- **W-06 GuestAgent.swift:47, 113-115, 128, 144, 191-193.** Resource leaks:
  - `processes` is never pruned;
  - a listener leaks when a later `listen` fails;
  - a `connectStreams` timeout orphans the guest process;
  - a `run` timeout does not kill it.
- **W-07 GuestAgent.swift:86-105, 286.** The readiness poll has no per-call deadline. The duplicated fd leaks if `Vminitd(connection:)` throws.
- **W-08 parbake-agent/GuestProcess.swift:44-92.** fd and vsock leaks on `start()` error paths.
- **W-09 parbake-agent/GuestProcess.swift:252-266.** A failed `waitpid` reports exit 0. `outputCopies.wait()` hangs when a background child holds stdout, so the exit is never reported.
- **W-10 parbake-agent/GuestProcess.swift:42-78.** A second StartProcess on one id spawns a second process. Fix: refuse it.
- **W-11 MacOSVirtualMachine.swift:195-210, 241-247, 363-382, 475-478.** Unstructured Tasks and waiters stay until the guest stops, and `queue.sync` runs on the cooperative pool.
- **W-12 RestoreImages.swift:93-104.** `curl` blocks a cooperative thread with no connect or speed timeout, no retry and no cancellation. A complete file without `.done` hits a 416 loop.
- **W-13 Provision.swift:158-170, Agent.swift:82-94, AgentProbe.swift:171-182.** Three copies of the wait-for-SSH loop, with blocking ssh, different intervals and no DHCP-vs-SSH distinction. Fix: one `waitUntilReachable` in RuntimeMacOS. This is stage 2 item 3.
- **W-14 GuestDHCPServer.swift:44-46.** The vmnet interface is not stopped on failure paths.
- **W-15 RuntimeService.swift:384.** The `vmnet_network_create_with_serialization` reference (CF_RETURNS_RETAINED) is never released.
- **W-16 MacOSVirtualMachine.swift:151-190.** The aux-storage lock surfaces raw EAGAIN after 30 s. The `NSUnderlyingErrorKey` walk has no cycle guard. Fix: a distinct "held by another process" error.

**Input validation and security hardening [R1]**

- **W-17 MacOSVirtualMachine.swift:263-274, 449-460; GuestAgent.swift:19, 253-255.** The host vsock stream listeners accept the first guest connection on predictable ports (CWE-290 / CWE-923). Fix: random ports plus a per-process token. Threat model: D-05.
- **W-18 GuestPreparation.swift:14-19.** `checkSudoCommand` allows `#`, `*`, whitespace, `=` and `:` into the sudoers line (CWE-20 / CWE-74). Fix: `^/[A-Za-z0-9._/+-]+$`.
- **W-19 Provision.swift:66.** The regex `$` matches before a trailing newline (CWE-20). Fix: `wholeMatch` and a length cap of 31.
- **W-20 GuestCredentials.swift:17-20, 113, 131.** `quoted()` does not escape a newline, so a username or service with a newline splits the `security -i` command (CWE-93). Fix: reject control characters in every argument.
- **W-21 DHCPMessage.swift:154.** `UInt8(nameservers.count * 4)` traps at 64 or more nameservers (CWE-190). Fix: cap or throw at configuration time.
- **W-22 DHCPLeases.swift:44.** `normalized` uses `compactMap`, so an invalid MAC becomes `[]` and matches garbage leases. Fix: return nil unless there are exactly 6 valid octets.
- **W-23 MacOSVMBundle.swift:47-52; RuntimeService.swift:118.** A missing directory reports "missing Disk.img". A relative or `~` label resolves against the helper's cwd. Fix: an explicit existence check, and refuse non-absolute paths.
- **W-24 MacOSVMBundle.swift:181-186, 219.** A container instance is accepted as a source bundle, because `instance(at:)` has no `hasOverlay` guard, and its live AuxiliaryStorage is cloned.
- **W-25 Create.swift:92-136; Install.swift:40, 46; Provision.swift:87; Layer.swift:56; GuestScript.swift:15; MacOSVirtualMachine.swift:90-97.** Input problems in `create` and the resource flags:
  - account flags are silently ignored without `--username`;
  - `--agent` together with `--no-agent` is accepted;
  - 0, negative or huge `cpus`, `memory` and `disk` values pass;
  - `<< 30` wraps silently;
  - values are silently clamped;
  - `--timeout` ≤ 0 is accepted.

  Fix: a `validate()` with ranges.
- **W-26 RestoreImages.swift:13, 36, 80, 96; Create.swift:144-159.** Restore-image source handling:
  - the cache key is the basename only;
  - `file://` is treated as a relative path;
  - a local path is checked late;
  - a non-`.ipsw` name is never pruned;
  - no `--proto-redir =https`.

**Errors and UX [R5]**

- **W-27 RuntimeService.swift:368.** `try? networkBootstrapInfos()` swallows a decode error, so the guest silently falls back to NAT. Fix: throw on a decode failure.
- **W-28 RuntimeService.swift:196-201; GuestAgent.swift:103.** The agent-timeout message does not name the `readiness-timeout` label or `parbake agent-probe`, and it prints "180.0 seconds".
- **W-29 Provision.swift:110.** The error omits ssh stderr. The twin at `Agent.swift:65-67` includes it.
- **W-30 Provision.swift:119; Agent.swift:71.** The ssh shutdown result is ignored, and the fallback is silent.
- **W-31 BundleConfiguration.swift:98.** A raw `DecodingError` dump, for example `[account]` without `username`. Fix: the coding path plus a short message.
- **W-32 RestoreImages.swift:156-163.** `try?` hides a failed rollback, leaving only `.parbake-old`. A cleanup failure after the swap is reported as a build failure.
- **W-33 Provision.swift:65; Install.swift:27, 51.** No line buffering, and `\r` progress without newlines, so CI logs show nothing during a 30-minute install.
- **W-34 AgentSetup.swift:12.** `CommandLine.arguments[0]` breaks the default agent path when `parbake` runs through PATH. Fix: `Bundle.main.executableURL`.
- **W-35 Create.apply (Create.swift:92-136).** Config booleans can only be turned on (no `--no-keychain` or `--no-tidy`). List flags replace the file's lists without saying so. That contradicts the README's "command line takes precedence".
- **W-36 GuestScript.swift (run).** The script is fed to `bash -s` on stdin, so a command that reads stdin swallows the rest. There is no `set -e`, which contradicts README's "a failing script fails the build". Fix: pass a file, and use `set -euo pipefail`.
- **W-37 GuestUser.swift; RuntimeService.swift:219-231.** `--user 501` and `--user root:wheel` fail, and `--uid 0` alone becomes the raw string "0". Fix: parse `uid[:gid]` and `name[:group]`, or document the forms.
- **W-38 RuntimeService.swift:291-295.** Any non-KILL signal shuts the guest down: HUP, USR1, WINCH and so on. README says "stop signals". Fix: accept TERM, INT and QUIT only, or document it. ADR 0003 also expects the kill path to wait, apply the 60 s floor and force a stop; it does not (spec seat).
- **W-39 scripts/dev-env.sh:80, 86, 130, 136, 142.** Problems in the dev script:
  - the state marker is deleted before the check, so `down` never restarts the installed services after a failed `up`;
  - `read` exits silently without a tty;
  - `cd` on a missing bundle gives a bare error;
  - `--cpus`, `--memory`, `-d` and `alpine` are hard-coded before ARGS;
  - `logs` fails on an empty glob;
  - `down` stops containers without a prompt.

**Architecture and duplication [R2], [R5]**

- **W-40 docs/adr/adr_0002 (Decision Outcome, "earlier than macOS 26 keeps NAT"), adr_0001 ("DiskImageKit is weak-linked"), adr_0003 ("No guest agent exists yet").** These clauses contradict `Package.swift:7` `.macOS("27")`. Fix: delete or amend them.
- **W-41 RuntimeService.swift:507; Provision.swift:119; Agent.swift:71; AgentProbe.swift:84; GuestPreparation.swift:37; AgentSetup.swift:43; GuestScript.swift:29-39.** The SSH shutdown string appears five times, and the stop ladder is coded four times with drift. Fix: move both into RuntimeMacOS (stage 2 item 3).
- **W-42 MacOSVMBundle.swift:231-241 vs 220-223.** `resetOverlay` does not refresh `Provisioned`, `GuestKey`, `Agent` or `HardwareModel` from a rebuilt base, so the key goes stale and SSH shutdown fails. Fix: reuse the `copyBundleFiles` set, and add a test.
- **W-43 parbake-agent/main.swift:9-11; GuestAgent.swift:15-17; AgentProbe.swift:67.** The environment variable name appears three times, the protocol number twice, and port 1024 twice. Fix: use `Vminitd.port` and `GuestAgent.versionVariable`.
- **W-44 AgentProbe.swift:34-37 vs AgentSetup.swift:9-18.** Duplicate agent-binary lookup. The "no Provisioned/GuestKey" check is repeated three times with different wording.
- **W-45 Create.swift:190-224.** Sub-commands are driven by re-parsing argv. Defaults are duplicated (`?? 4`, `?? 8`), and the timeout 300 is hard-coded. `Agent.swift:56` and `AgentProbe.swift:44` hard-code CPUs and memory.
- **W-46 .github/workflows/ci.yml:36.** The cache key lacks `Package.resolved`, so a new fork pin reuses a stale build.
- **W-47 MacOSVMBundle.swift:289-295.** The clone falls back to a full copy silently, with no warning and no space check.
- **W-48 DHCPLeases.swift:5, 37-42 (CLI paths only).** The bootpd lease file can miss a client-id lease and runs out of addresses with 24 h leases. Fix: name the pool and lease file in the timeout message.
- **W-49 parbake agent install vs layers (Agent.swift).** Installing an agent into a base breaks the layers made from it, whose `Agent` marker goes stale. The warning names containers only.

**Spec and doc drift [R6], [R7]**

- **W-50 parbake-agent/GuestProcess.swift:310.** C-002 lists `gid` and `additionalGids`. The agent ignores them, while the runtime forwards `supplementalGroups` (`RuntimeService.swift:229`).
- **W-51 parbake-agent/GuestProcess.swift:311.** A cwd of `/` is silently rewritten to home for non-root users (`a || b && c`). Fix: document it in C-002, or use `isEmpty` only.
- **W-52 parbake-agent/GuestProcess.swift:96-150.** C-003 `consoleSize` is never applied (`TIOCSWINSZ`).
- **W-53 docs/specs/spec_guest_agent.md:5, 301-303; spec_bundle_rebuild.md:170-172.** Status is still Draft, and the Approval boxes are unchecked.
- **W-54 AGENTS.md.** bundle_rebuild C-004 requires AGENTS.md to name `--restore-image` and `--replace`; it does not. AGENTS.md:13 names a local fork branch instead of the pinned fork tag.
- **W-55 docs/adr/adr_0001:127.** An unchecked item sits in an Accepted ADR.
- **W-56 container-runtime-macos-proposal.md:1-5.** An unfinished "Notes before posting" block, written in the first person as an upstream post with stale references. Fix: move it out of the repo, or finish it.
- **W-57 docs/architecture.md:237-266; README.md:75-76.** Analogy and rationale outside the ADRs (writing rule).
- **W-58 Taskfile.yml:40-120 vs CONTRIBUTING.md.** The task table is incomplete.
- **W-59 docs/adr/adr_0008.** It says a failed `run -d` leaves the container "stopped"; the CLI deletes it, and `--cidfile` goes stale. There is no concrete `inspect` command or poll advice, and `run` failure causes cannot be told apart.
- **W-60 README.md (Run).** It says the image is "otherwise unused", but the CLI fetches it before every run. `container logs` is empty. The job's effective PATH and environment are undocumented.
- **W-61 Create.swift:213-224 (headless).** `--config` without `[account]` opens a Setup Assistant window on a headless host, and there is no `no-setup` config key.
- **W-62 Tests.** Coverage gaps the panels flagged:
  - there are no test targets for `parbake-agent` and `container-runtime-macos`, which also cover `VsockFront` CID==2, `Launch`, `ProcessTable`, `isKill` and `ociProcess`;
  - weak `throws: (any Error).self` assertions in `GuestProvisioningTests.swift:63-85` and `BundleConfigurationTests.swift:84-106`;
  - string-matching tests (`GuestProvisioningTests.swift:162-171`, `GuestAgentInstallationTests.swift:36-41`);
  - no free-space-refusal or layer-refuses-instance tests;
  - `BundleConfiguration` and `RestoreImages` failure paths are not covered;
  - the `isLockContention` retry loop is untested.

  Root cause: [R8], which is stage 2 item 1.

### Suggest

- **S-01 RestoreImages.swift:44-63.** `.done` plus VZ load is stronger than comparable caches. Keep it.
- **S-02 GuestAgentInstallation.swift:11, 51.** Fixed `/tmp` staging path (CWE-377 / CWE-367). Use `mktemp -d`.
- **S-03 parbake-agent/GuestProcess.swift:309-323.** Environment keys go to `env -i` without `--` (CWE-88). Validate the keys.
- **S-04 GuestDHCPServer.swift:74-102; RuntimeService.swift:~421.** Per-frame copy, and unbounded per-request logging (CWE-400). Pre-filter UDP 67 and rate-limit.
- **S-05 parbake-agent/VsockFront.swift:48-53.** EMFILE in `accept` causes a hot spin. Back off.
- **S-06 parbake-agent/main.swift:37.** A negative port argument traps.
- **S-07 parbake-agent/GuestProcess.swift:208-243.** Four threads per process. A poll loop would scale better.
- **S-08 GuestScript.swift:52.** No script timeout.
- **S-09 Create.swift:165-173.** No free-space check before the IPSW download.
- **S-10 AgentSetup.swift:62-72.** An empty tty password is accepted, and input is truncated at 1023 bytes.
- **S-11 ParbakeTool.swift:8; RuntimeMacOSHelper.swift:8.** Two version strings (audit item 8).
- **S-12 ParbakeTool.swift:9-18.** `agent-probe` and `state-probe` are listed unhidden in `--help`.
- **S-13 Provision.swift:66-68.** The username message does not state the first-character rule.
- **S-14 Package.swift:30.** Unused `GRPCCore` dependency in the plugin target.
- **S-15 docs/architecture.md (readiness).** The example `"1 0.52.0"` does not match the agent's `"1"`.
- **S-16 config.toml.** No comment on the `[runtimeConfig]` flags.
- **S-17 Tests/RuntimeMacOSTests/GuestAgentTests.swift:7-33.** Add overflow and odd-case protocol and signal inputs.

---

## Usage simulation (design mode)

| Pattern | Verdict | Top findings |
|---|---|---|
| first-time | **fails unaided** | H-16, H-17, H-18, H-08, H-24; W-33 |
| power-user | with friction | H-06, H-11, H-08, W-37, W-38, W-35, W-36 |
| adversarial | with friction | H-01, H-08, H-09, W-04, W-10, W-20 |
| automation | with friction | H-12, H-07, H-05 (from `create`), W-59, W-60, W-61, H-18 |

Simulator claims recorded as *unverified* by their seat:

- whether exec inherits the Linux image's PATH;
- `ls`/`inspect` showing `linux/arm64`;
- whether a locked keychain returns status 44.

---

## Deferred findings (human judgment required)

- **D-01 [High] Sources/container-runtime-macos/RuntimeService.swift:93, 118; MacOSVMBundle.swift:217-247.** The `runtime-macos.bundle` path has no allow-list (CWE-22 / CWE-73). This is audit item 4.
  - Needed: canonicalize the path with symlinks resolved; require it under a configured root; require the current uid as owner and no group or world write; refuse symlinked layout files, since `clonefile` follows them.
  - Question: what is the configuration surface for the roots (`PARBAKE_HOME`, or a `bundle-roots` list in the plugin config)?
  - Ship with H-13.
- **D-02 [High] Sources/parbake/Create.swift:63; Provision.swift:45; GuestPreparation.swift:46-52.** `--sudo` / `[guest] sudo` grants arbitrary NOPASSWD commands beyond ADR 0003's `/sbin/shutdown`, and `--config` / `--script` has no spec. Needs a spec or an ADR, or removal.
  - Grade: spec seat Warn; raised to High as a security-relevant surface with no decision record.
- **D-03 [Warn] ci.yml:3-8, 15.** Is `xcode-27` self-hosted, and will the repo be public? If both, gate fork PRs.
- **D-04 [Warn] GuestShell.swift:70.** The password in the environment is an accepted trade-off, or the askpass should move to an fd.
- **D-05 [Warn] Guest-side threat model.** Are non-root guest tenants in scope? That decides W-17 and the agent's pid/signal acceptance (`SandboxService.swift:141-145`).
- **D-06 [Warn] parbake exit-code contract.** Publish distinct codes for timeout, script and usage failures, and document them in README and ADR 0008.
- **D-07 [Warn] Readiness timeouts.** Four different defaults: 900 / 300 / 120 / 180 s (`Provision.swift:63`, `Agent.swift:45`, `GuestAgentInstallation.swift:16`, `RuntimeService.swift:31`). Pick them, and decide whether `create` exposes one.
- **D-08 [Warn] create resume.** Keep an installed but unprovisioned bundle on failure, so a retry skips the install?
- **D-09 [Warn] Bundle layout format version.** There is none. Instance links are absolute (`MacOSVMBundle.swift:244-247`).
- **D-10 [Warn] Mounts and file transfer for CI jobs.** virtiofs, agent copy (C-007, out of scope today) or SSH? An ADR candidate.
- **D-11 [Warn] Host session requirement.** The apiserver runs in `gui/<uid>`. Is an auto-login GUI session on CI hosts an accepted requirement?
- **D-12 [Warn] `container start` of a leftover container.** It resumes the previous job's disk (`RuntimeService.swift:119-122`). Is that allowed under "ephemeral"?
- **D-13 [Warn] Failed-bootstrap cleanup policy.** Auto-delete `vm/`, or keep it for debugging? This is the product side of H-01.
- **D-14 [Warn] Restore-image cache policy.** A stale `.ipsw` without `.done`; a size cap.
- **D-15 [Warn] Keychain, hdiutil and ASIF tests in CI** (with H-25), and the CI coverage, timeout and retry policy.
- **D-16 [Suggest] Agent as the default exec path.** SSH would become bootstrap only, with a fixed exec wrapper.
- **D-17 [Suggest] Probes and spikes.** `agent-probe`, `state-probe` and `saveState`/`restoreState`: hide them or remove them before release.
- **D-18 [Suggest] Unspecified flags.** `--no-setup`, `--keychain-service`, `--tidy`, `layer --cpus/--memory/--timeout` and the agent's `--controlling-terminal`: which belong in a spec table?
- **D-19 [Suggest] Scheduled for `/hex-architect`.** (a) parbake importing Virtualization and AppKit (the bypass at `Setup.swift:28`). (b) The agent protocol version as a string with no range, and the bundle `Agent` marker used only as a flag.
- **D-20 [Suggest] init-process signal semantics, and `--uid 0` meaning the CI account.**
- **D-21 [Suggest] Whether `PARBAKE_HOME` should cover `layer --bundle` and the label.**

---

## Root-cause analysis

### R1 — Input is trusted at the use site

Members: H-13, H-14, W-18, W-19, W-20, W-21, W-22, W-23, W-25, W-26, S-02, S-03, D-01.

- Why 1: values reach ssh argv, sudoers, heredocs and the `security -i` command line unvalidated.
- Why 2: validation exists only at the CLI that first writes the value, for example `Provision.swift:66`.
- Why 3: values travel as `String` through files in the bundle, and are read back as trusted.
- Why 4: there is no typed value (Username, SudoCommand, BundlePath, KeyLine) that can be constructed only through validation.
- Why 5: the script-building helpers were written per command, with syntax tests only.

**Systemic fix:** one `Validated` module in RuntimeMacOS with full-match parsers. Every reader (bundle files, labels, TOML, CLI) goes through it, and the script builders accept only those types. Add a hostile-input table test.

### R2 — Ad-hoc blocking subprocess and I/O handling

Members: H-02, H-03, W-01, W-02, W-03, W-11, W-12, W-13, W-41, S-05, S-08.

- Why 1: ssh, security and curl are run synchronously with no deadline, and writes do not throw.
- Why 2: each of the five `Process()` sites hand-rolls the setup, the drain and the wait.
- Why 3: there is no shared async process runner.
- Why 4: SIGPIPE hardening was added where a crash was seen (the plugin helper), not at every entry point.
- Why 5: none of the paths is tested without a VM.

**Systemic fix:** one async `ProcessRunner` with these properties:

- a timeout and cancellation that terminate the child;
- concurrent drain;
- a throwing write;
- a minimal environment;
- the hardened ssh options.

Call `signal(SIGPIPE, SIG_IGN)` in all three executables. This matches stage 2 item 3.

### R3 — Filesystem state changes are not atomic

Members: H-01, H-08, H-09, W-24, W-32, W-42, D-08, D-13.

- Why 1: a failure or a concurrent run leaves a partial instance or bundle, or deletes another run's output.
- Why 2: instances and bundles are built in place, with no stage-then-rename. `BundleReplacement` does this for `--replace` only.
- Why 3: validity is a file-existence test.
- Why 4: there is no lock on the bundle or the cache.
- Why 5: the instance lifecycle has no failure-path tests.

**Systemic fix:** build every instance and bundle in a sibling staging directory, and rename it on success. Take an flock on the target and the cache. Make `MacOSVMBundle(url:)` check layout completeness by kind (base, layer, instance). Add failure-injection tests.

### R4 — Actor state machine checked before awaits

Members: H-06, W-04, W-05, W-10.

- Why 1: state is read, an await happens, and the state is then written unconditionally.
- Why 2: there are no transitional states (`.starting`), and `.stopping` is not treated as running for KILL.
- Why 3: the state transitions are not written down as a table.
- Why 4: `RuntimeService` has no test target.

**Systemic fix:** write an explicit transition table, re-check state after every await, and unit-test it through an injected VM protocol (stage 2 item 1).

### R5 — No error taxonomy

Members: H-05, H-07, H-12, H-24, W-16, W-27, W-28, W-29, W-30, W-31, W-33, D-06.

- Why 1: users get raw VZ, POSIX and `security` text, or exit 64 with usage.
- Why 2: errors are ad hoc: `ValidationError` used for runtime failures, and `ContainerizationError` with free text.
- Why 3: no module owns the failure list the audit names.
- Why 4: no exit-code or message contract exists outside ADR 0008's exec rows.

**Systemic fix:** one error type per module, with cases for the audit requirement 9 list: lock held, DHCP timeout, SSH timeout, agent timeout, keychain locked, missing bundle, VZ code 6 (leaked slot). Map them to exit codes, add an `os_log` subsystem, and write a documented exit-code table.

### R6 — Docs not verified against a clean setup

Members: B-01, B-02, B-03, H-04, H-11, H-16 to H-23, W-54 to W-61.

- Why 1: the README misses steps and claims, and the fork pin misses a commit.
- Why 2: everything was written from the author's working environment (a local fork checkout at the branch tip, installed services).
- Why 3: no clean-machine walk-through, and no docs check in CI.
- Why 4: the release checklist has no docs gate.

**Systemic fix:** pin the fork's branch tip. Add a docs checklist (or `/docs-review`) to the release gate. Make audit requirement 10's end-to-end run start from a clean clone that follows only README and CONTRIBUTING.

### R7 — Spec clauses not tied to tests

Members: B-04, H-10, W-50, W-51, W-52, W-53.

- Why 1: C-002 and C-003 clauses shipped unimplemented, and C-005 names routes that do not exist.
- Why 2: no test names a C-n ID.
- Why 3: the agent has no test target.

**Systemic fix:** name a test after each C-n where it is VM-free, and add an agent test target (stage 2 item 1). Check each spec's Status against its V-n table in the release gate.

### R8 — Missing test seams and undeclared host dependencies

Members: H-14, H-15, H-25, W-62, D-15. This is stage 2 items 1 and 2.

**Systemic fix:**

- Executables: put protocols at the VM, process and shell seams, and add test targets for the plugin and the agent.
- Host-dependent tests: tag them and gate them by trait.
- Parsers and script builders: add parameterized negative tests.

**Cross-cutting note:** R1, R2, R3, R5 and R6 each touch at least three findings. That alone triggers the xhigh/max rule "systemic cause affecting ≥3 findings → Request Changes".

---

## Convergence and Fold-Back

- Convergence: not applicable. The target does not trace to a plan artifact; `hex.md › Memory` has no active plan pointer.
- Fold-Back: not performed. The target does not trace to a plan.

## Cross-Model Adversarial

Skipped: `hex.md › Preferences` pins no adversary, and no second harness is on `PATH`. One review layer is missing from this run.

## Next step

The fixes belong to the release-audit loop's stage 1 (`/hex-execute "apply max-tier review findings"`). Every Block and High must be fixed, or recorded in an ADR as a deliberate deviation, per stage 1 item 1. D-01, D-02 and D-19 feed the scheduled `/hex-architect` run and requirements 4 and 5.
