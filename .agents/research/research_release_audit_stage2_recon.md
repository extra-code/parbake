# Research: release audit stage 2 recon (sites at HEAD 12aa486)

Discover output of `/hex-plan` for [plan_release_audit_stage2.md](../plans/plan_release_audit_stage2.md). It
re-locates every stage 2 site from [the discussion](../discussions/release-audit.md) › Stage 2 after stage 1.
Line numbers are for `12aa486` on `hex/release-audit`. "RM" is `Sources/RuntimeMacOS/`, "RS" is
`Sources/container-runtime-macos/RuntimeService.swift`. Reused research: `research_release_audit_full_review.md`
(R2, R4, R5, R8, W-04, W-13, W-41, W-62, S-07) and `research_release_audit_stage1_review.md` (F-24, F-26, F-29, F-41).

## 1. Plugin seams (`Sources/container-runtime-macos/`)

- Routes: `RuntimeMacOSHelper+Start.swift:68-96`. `createEndpoint` on the mach service (68-74); the rest on the
  anonymous connection. `dial`, `statistics`, `copyIn`, `copyOut`, `snapshotDisk` and `clean` map to
  `unsupported`.
- `RuntimeService` is an actor (RS:19). States (RS:42-49): `created`, `prepared`, `running`, `stopping`,
  `stopped`, `shuttingDown`.

| Route | RS lines | Message input | Collaborators |
|---|---|---|---|
| createEndpoint | 76-81 | — | `xpc_endpoint_create` |
| bootstrap | 85-176 | network infos | `RuntimeConfiguration`, `RuntimeLifecycle.unsupportedInputs`, `BundlePathPolicy`, `MacOSVMBundle`, `allocateNetwork`, `MacOSVirtualMachine(...)`, `resetOverlay` |
| startProcess | 185-234 | `id()` | `virtualMachine.start/wait/forceStop`, `GuestAgent(virtualMachine:)`, `waitUntilReady`, `AgentVersionLine` |
| createProcess | 238-245 | `id()`, `processConfiguration()`, `stdio()` | `ociProcess` (248-261, static), `agent.createProcess` |
| state | 264-282 | — | state → `RuntimeStatus` switch 267-277 |
| stop | 286-300 | `runtimeStopOptions()` | `stopGuest` (492-507) |
| kill | 306-334 | `id()`, `signal` | `RuntimeLifecycle.initSignalAction`, `forceStop`, `shutDown`, `requestStop` |
| resize | 338-348 | `id()`, `width`, `height` | `agent.resize` |
| wait | 352-365 | `id()` | `processExit` (370-378) |
| shutdown | 381-392 | — | `agent?.close()`, `releaseNetwork` (463-469) |
| unsupported | 396-398 | — | — |

- No `protocol` exists in `Sources/`. VZ leaks into RS: `import Virtualization` (11), `VZMACAddress` (422),
  `vmnet_network_create_with_serialization` (419); network setup at 402-461.
- `GuestAgent.init(virtualMachine: MacOSVirtualMachine)` (GuestAgent.swift:46) binds the agent to the concrete VM.
- A test target can depend on the executable target: `@testable import container_runtime_macos`. `XPCMessage(route:)`
  and its setters are public (fork `Sources/ContainerXPC/XPCMessage.swift:46`); handlers can be called
  directly. The target pulls the fork's `container` products, so the test build is slower.
- F-26: guard `state == .prepared` RS:193-195, suspension at 198, `.running` at 204. `stop` (295) and
  `shutdown` (383) both accept `.prepared` during that window.
- F-24: `Task.detached { shell.run(...) }.value` RS:549-551; the post-check at 552 compares
  `self.virtualMachine === virtualMachine`, which is always true. `kill`'s `.forceStop` (322-323) sets no flag.
  ssh holds a pool thread up to 60 s (RS:40, 494).
- F-41: `OSLogHandler.render(message:metadata:)` (31-35) and `osLogType(_:)` (37-45) are pure statics.

## 2. Agent (`Sources/parbake-agent/`)

| Op | SandboxService | Implementation |
|---|---|---|
| createProcess | 76-99 | `GuestProcess.init` 29-36, `ProcessTable.add` |
| start | 101-108 | `GuestProcess.start()` 44-92; pty path 96-143 |
| wait | 110-118 | `GuestProcess` 159-171 |
| kill | 120-125 | `signal` 174-182, `kill(-pid, sig)` |
| delete | 127-132 | `ProcessTable` 20-26 |
| closeStdin | 134-139 | 185-199 |
| resize | 218-223 | 146-156, `TIOCSWINSZ` |

- Host processes can stand in: as non-root with the caller's uid, `Launch.init` takes the plain `posix_spawn`
  branch (GuestProcess.swift:314). The only host blocker is vsock, `VsockConnection.toHost` (67-69, 112-113);
  with all stream ports nil, `start()` needs none.
- The pty path re-execs `Bundle.main.executablePath` (339-343), which is the test runner under `swift test`.
- Force unwraps: GuestProcess.swift:223 `$0.baseAddress! + offset`; GuestProcess.swift:507
  `body($0.baseAddress!)`. No other `!`, `try!` or `as!` in the agent.
- `Process()` sites: GuestProcess.swift:439 (`sudo -u <name> -- getconf DARWIN_USER_TEMP_DIR`), GUISession.swift:15
  (`launchctl print gui/<uid>`).
- Errors: `AgentError` (AgentError.swift:5); `SandboxService.unimplemented` (261-263) builds an `RPCError` itself.

## 3. Duplication

- `Process()` in host code: GuestShell.swift:121 (ssh), GuestCredentials.swift:205 (`security -i`),
  RestoreImages.swift:107 (curl), parbake/Provision.swift:150 (ssh-keygen). GuestShell's runner (drain threads
  140-152, stdin writer, TERM, 2 s, KILL at 160-166, `Result.status == -1` on spawn failure) is the most complete.
- Pipe drains: GuestShell.swift:140-152; GuestCredentials.swift:219-224 (stderr thread, inline stdout read,
  `usleep` spin).
- `sudo -n /sbin/shutdown -h now`: GuestPreparation.swift:48, parbake/Provision.swift:124, parbake/Agent.swift:71,
  parbake/AgentProbe.swift:87, RS:547 (`sudo -n -l /sbin/shutdown && echo accepted && …`). Agent-side argv:
  GuestAgent.swift:205 (root) and :209 (sudo).
- `sudo -S`: GuestPreparation.swift:67, GuestAgentInstallation.swift:66, both
  `printf '%s\n' "$PARBAKE_PASSWORD" | sudo -S -p '' /bin/sh -c "$PARBAKE_ROOT"`.
- Wait loops: Provision.swift:163 `waitForAccount` (5 s; DHCP vs SSH; last ssh error), Agent.swift:82 and
  AgentProbe.swift:174 `waitForSSH` (3 s), AgentProbe.swift:190 `dialAgent` (1 s, vsock), GuestAgent.swift:82
  `waitUntilReady` (1 s), MacOSVirtualMachine.swift:157 lock retry (2 s, 30 s). Stop ladder: AgentSetup.swift:40
  `waitForStop` (180 s, `requestStop`, 60 s, `forceStop`), RS `stopGuest` 492-507. `Setup` and `Layer` have no
  loop.
- Errors: RM has `RuntimeFailure`, `BundlePathError` (BundlePathPolicy.swift:102), `IncompatibleOverlayError`
  (MacOSVMBundle.swift:35), `GuestAgent.VersionMismatch` (21), `GuestAgent.ProcessLost` (32, `cause: any Error`)
  and 51 `ContainerizationError(` sites. parbake has `ParbakeError` plus 17 `ValidationError(` sites. The plugin
  has 21 `ContainerizationError(` sites and no type. `keychainLocked`/`keychainRefused` are thrown only inside
  `RuntimeFailure.swift`'s callers in GuestCredentials.
- DHCPLeases.swift:30 `lease >= newest!.lease`. No other force unwrap in RM or parbake.

## 4. Pure logic

- GuestShell: `arguments(...)` (51-80) is tested for the common options only (GuestShellTests.swift:18); the
  credential-specific options, `--` placement and `seconds()` (172) are not. Askpass and environment are built
  inline in `run` (108-123).
- GuestDHCPServer is vmnet I/O; `readFrames` (93-100) does parse → reply → write. A `respond(to:lease:serverMAC:)`
  and the start-callback parse (31-37) can be extracted. DHCPMessage `ipChecksum` (180), `ipv4()` (192), `mac()`
  (198) and `mask(prefixLength:)` (204) have no direct tests.
- MacOSVirtualMachine: `mapStartError`, `isLockContention`, `errorChain` are tested. `finish` (414-431), `wait`
  (371-385), `wait(timeout:)` (388-407), `currentExit` (410) need an instance; the CPU clamp and memory floor in
  `configuration(...)` (67-132) are inline.
- DHCPLeases `currentAddress` and its `>=` tie-break are untested; `curl()` and `createGuestKey` are untested.

## 5. Coverage and the end-to-end run

- Tests are Swift Testing only. `.build/debug` holds one bundle per test target (`RuntimeMacOSTests.xctest`, …),
  not a `<package>PackageTests.xctest`. `swift test --show-codecov-path` names the JSON beside
  `default.profdata`. `xcrun llvm-cov report -instr-profile <profdata> <obj> -object <obj>…` with
  `-ignore-filename-regex '\.build|/Tests/|checkouts'`; per-module totals come from summing per-file lines by
  `Sources/<module>/`.
- `scripts/dev-env.sh up` builds the checkout and runs `task install INSTALL_ROOT=<container src>`; it never uses a
  release build. `scripts/release.sh build X.Y.Z` stamps a detached sibling worktree, runs `task check` there and
  copies the three signed binaries to `.build/release-assets/X.Y.Z/`. A stamped plugin reaches the development
  services only by copying it into `<container src>/libexec/container-plugins/container-runtime-macos/bin/`.
- `docs/end_to_end_checklist.md` › Recorded runs forbids build identifiers, signing identifiers, volume names,
  commit hashes and timings in the repo.

## 6. F-29

`GuestCredentials.password(for:)` creatorOnly branch (88-100) reads an `-A` item and leaves it open. A re-store is
about 8 lines, but whether `SecItemDelete` of an `-A` item from a team-signed binary prompts is exactly what ADR
0010 measured for other operations, and no unit seam exists (`SecItem*` direct; the round-trip test is gated on a
non-ad-hoc test runner). ADR 0010 lists the open item as a known negative.
