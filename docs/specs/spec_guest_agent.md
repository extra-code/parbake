# Spec: Guest agent — processes, readiness and shutdown over vsock

## Overview

**Status:** Draft
**Author:** Christian Semmelmann
**Date:** 2026-10-18
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Decision of record:** [ADR 0006](../adr/adr_0006_guest_agent_speaks_the_sandbox_context_protocol.md)
(Status: **Accepted**, 2026-10-18). This spec details what that ADR decided.

A macOS guest gets an agent that serves the macOS subset of containerization's `SandboxContext`
gRPC service on vsock port 1024. The runtime talks to it through containerization's `Vminitd`
client. The agent replaces SSH for running processes (`container exec`), for knowing when the guest
is ready, and for shutting the guest down.

The container's init process stays the guest itself: `container start` boots it, and the container
exits when the guest shuts down. Every other process is an agent process.

## Goals

- **`container exec`** runs a process in the guest with separate stdin, stdout and stderr, a PTY on
  request, resize, close-stdin, signals and its exit status — the same routes as for a Linux guest.
- **Readiness:** `container run -d` and `container start` return once the agent answers, so a caller
  needs no polling.
- **Processes in the logged-in session** of the guest account, so the Keychain, code signing and
  simulators work.
- **Shutdown through the agent**, SSH and the power-button request as fallbacks (ADR 0003).
- **No IP traffic** between runtime and agent.

## Non-goals

- Mounts, sysctl, network configuration, DNS and hosts files, emulators and vsock proxying: the
  Linux-only RPCs. They return `UNIMPLEMENTED`.
- Container statistics. Later, once a consumer needs them.
- File copy (`container cp`) in the first slice; C-007 reserves it.
- Running more than one guest account's processes concurrently in different sessions.
- Updating an installed agent from inside a running guest.

## User / Interaction Flow

1. **Provisioning** installs the agent (C-006) in the same SSH session as the other preparation and
   records `Agent` in the bundle with the agent's protocol version.
2. **`container run -d … --runtime container-runtime-macos`:** the runtime boots the guest, dials
   vsock port 1024 every second, and calls `Getenv` for the agent version (C-005). `startProcess` of
   the init process replies once the agent answers with a matching version, or fails after the
   readiness timeout.
3. **`container exec mac1 xcodebuild …`:** the runtime allocates host vsock ports for the requested
   streams, listens on them, calls `CreateProcess` with the OCI process and the port numbers, then
   `StartProcess`. The agent connects each stream to the host, spawns the process in the account's
   session and reports its exit through `WaitProcess`.
4. **`container stop mac1`:** the runtime starts `/sbin/shutdown -h now` as root through the agent
   and waits for the guest to stop (at least 60 s, ADR 0003). Without an agent it uses SSH, then the
   power-button request.

## Component / Module Specifications

### C-001 — `parbake-agent`: the executable in the guest

- An executable target of this package, arm64 macOS, built and signed with the package. It links
  containerization (for the generated service protocol and message types) and grpc-swift-2.
- Runs as a LaunchDaemon (root): label `container-runtime-macos.agent`, program
  `/usr/local/libexec/parbake-agent`, `KeepAlive` and `RunAtLoad` true.
- Listens on `AF_VSOCK`, any CID, port 1024. Accepts a connection only when the peer CID is
  `VMADDR_CID_HOST` (2); processes inside the guest cannot reach it.
- Serves `SandboxContext.SimpleServiceProtocol`. RPCs outside C-002 to C-004 and C-007 throw
  `RPCError(code: .unimplemented)`.
- Logs to the unified log, subsystem `container-runtime-macos.agent`.

### C-002 — Process creation and the account's session

`CreateProcess(id, stdin?, stdout?, stderr?, configuration)` decodes `configuration` as an OCI `Spec`
and records the process; `StartProcess(id)` spawns it and returns its PID.

| OCI field | Use |
|---|---|
| `process.args` | argv; `args[0]` resolved against `PATH` from `process.env` |
| `process.env` | the environment, after the account defaults below |
| `process.cwd` | working directory; empty means the account's home |
| `process.user.uid`, `gid`, `additionalGids`, `username` | identity, after the runtime's mapping in C-005; `username` wins over `uid` when both are set |
| `process.terminal` | PTY on request (C-003) |
| `process.consoleSize` | initial PTY size |
| everything else (`root`, `mounts`, `linux`, rlimits, capabilities) | ignored |

- **root (uid 0):** spawned directly by the agent.
- **Any other account:** spawned in that account's per-session bootstrap namespace —
  `launchctl asuser <uid>` — and then with the account's uid, gid and supplementary groups
  (`initgroups`), so it reaches `securityd`, the login keychain and the window server like a process
  the account starts itself. When the account has no GUI session, `CreateProcess` fails with
  `FAILED_PRECONDITION` and says so.
- **Environment defaults:** `HOME`, `USER`, `LOGNAME`, `SHELL` from the account record, `PATH`
  `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`; `process.env` overrides them.
- Process IDs are unique per agent run; a second `CreateProcess` with a known ID fails with
  `ALREADY_EXISTS`.
- Every process starts in a process group of its own, with default signal dispositions and an empty
  signal mask, and inherits no descriptor but 0 to 2. An ignored signal survives `exec`: without the
  reset, a process inherits whatever the agent's launcher ignored, and an inherited ignored SIGTERM
  never stops it.
- An agent that does not run as root starts processes only as its own account and refuses any other
  with `FAILED_PRECONDITION`.

### C-003 — Standard streams

- For each port in the request, the agent connects to `VMADDR_CID_HOST` on that port before
  `StartProcess` returns; a failed connection fails `StartProcess`.
- Without a terminal: stdin, stdout and stderr are separate pipes copied to and from their
  connections.
- With a terminal: one PTY (`openpty`); its output goes to the stdout connection, stdin feeds it, no
  stderr connection is used. `ResizeProcess` sets the size (`TIOCSWINSZ`).
- `CloseProcessStdin` closes the process's stdin.
- Output still buffered when the process exits is written before `WaitProcess` returns.

### C-004 — Wait, signal, delete

- `WaitProcess(id)` blocks until the process exits and returns its exit code — `128 + signal` for a
  signalled process — and the exit time.
- `KillProcess(id, signal)` sends the signal to the process group of the process.
- `DeleteProcess(id)` forgets an exited process; deleting a running one fails with
  `FAILED_PRECONDITION`.
- `Kill(pid, signal)` sends a signal to any guest PID, for the runtime's own use only.
- `Sync` calls `sync(2)`.
- `SetTime(sec, usec)` sets the guest clock (`settimeofday`), for guests restored from a saved state.

### C-005 — Runtime: readiness, version, routes

- `MacOSVirtualMachine` exposes a vsock dial (`VZVirtioSocketDevice.connect(toPort:)`) and listeners
  (`setSocketListener(_:forPort:)`); the runtime wraps a connection's file descriptor in `Vminitd`.
- **Readiness:** after the boot the runtime dials port 1024 once per second. The agent is ready when
  `Getenv("CONTAINER_RUNTIME_MACOS_AGENT")` returns its version, `<protocol> <containerization
  version>`, for example `1 0.52.0`. The protocol number changes only when this spec changes the wire
  contract; the containerization version is informational.
- **Readiness gate:** a bundle with `Agent` makes `startProcess` of the init process reply only when
  the agent is ready, within the label `runtime-macos.readiness-timeout` (default 180 s); on timeout the guest is stopped and the start fails. A bundle without `Agent` replies after
  the boot, as today.
- **Version mismatch:** a protocol number the runtime does not know fails readiness with a message
  that names both versions and `parbake agent install`.
- **User mapping:** the runtime builds the OCI user from the process configuration's `User`.
  `.id(uid: 0, gid: 0)` — what `container exec` sends without `--user`, since it takes the init
  process's user and that is the default — becomes the provisioned account from `Provisioned`
  (`username` set). `.raw(userString:)` passes as `username`, so `--user root` runs as root.
  `.id` with another uid passes as `uid`/`gid`. A bundle without `Provisioned` keeps root.
  `--uid 0 --gid 0` arrives as `.id(0, 0)` too and therefore runs as the provisioned account; root is
  `--user root`.
- **Routes:** `createProcess`/`startProcess`/`resize`/`closeStdin`/`wait`/`kill`/`delete` for a
  process other than the init process map to the agent through `Vminitd`, with host ports from a
  per-container allocator starting at 0x10000000. The init process keeps its routes.
- **Stop:** `stop` and `kill` with any signal but SIGKILL for the init process start
  `["/sbin/shutdown", "-h", "now"]` as root through the agent; when that fails, ADR 0003 applies.

### C-006 — Installation and update

- `parbake provision` copies the agent binary and its LaunchDaemon property list into the guest in
  the preparation SSH session, loads it with `launchctl bootstrap system`, waits for `Getenv` over
  vsock from the provisioning process, and writes `Agent` (the version line) into the bundle.
- `parbake agent install --bundle <path>` boots a provisioned bundle once, installs the agent from
  this build over SSH with `GuestKey`, updates `Agent`, and shuts the guest down. It is the update
  path for existing bundles and after a protocol change.
- Instances copy `Agent` like `Provisioned` and `GuestKey`.

### C-007 — File copy (reserved)

`WriteFile`, `Stat` and `Copy` for `container cp`, following the Linux agent's semantics. Not in the
first slice; until then they return `UNIMPLEMENTED`.

## Interface Contract

### RPCs served

| RPC | Served | Component |
|---|---|---|
| `CreateProcess`, `StartProcess`, `WaitProcess`, `KillProcess`, `DeleteProcess` | yes | C-002, C-004 |
| `ResizeProcess`, `CloseProcessStdin` | yes | C-003 |
| `Getenv` | yes (agent's own environment; readiness) | C-005 |
| `Kill`, `Sync`, `SetTime` | yes | C-004 |
| `WriteFile`, `Stat`, `Copy` | later | C-007 |
| all other `SandboxContext` RPCs | `UNIMPLEMENTED` | C-001 |

### Bundle files (new)

| File | Content | Written by |
|---|---|---|
| `Agent` | the agent version line, e.g. `1 0.52.0` | `parbake provision`, `parbake agent install` |

### Container labels (new)

| Label | Meaning | Default |
|---|---|---|
| `runtime-macos.readiness-timeout` | seconds to wait for the agent after the boot | `180` |

## Non-Functional Requirements

- **Security:** the agent runs as root and accepts connections from the host CID only. vsock reaches
  it only through the `VZVirtioSocketDevice` that the runtime's process owns. Processes run as the
  requested account; root only when the OCI user is uid 0.
- **No IP:** no part of this flow opens an IP socket between host and guest.
- **Latency:** readiness within 5 s of the guest's login on this host's hardware; `exec` of `true`
  completes in under 200 ms after readiness.
- **Robustness:** a lost agent connection fails the calls in flight with `UNAVAILABLE`; the runtime
  redials on the next call. The agent restarts through `KeepAlive` without losing the guest.

## Traceability

| Goal | Components | Validation |
|---|---|---|
| `container exec` | C-002, C-003, C-004, C-005 | V-2, V-3, V-4 |
| Readiness | C-005, C-006 | V-1, V-5 |
| Logged-in session | C-002 | V-4 |
| Shutdown through the agent | C-005 | V-6 |
| No IP | C-001, C-005 | V-1 |

**Validation:**

- **V-1 (spike) — passed 2026-10-18:** `parbake agent-probe --bundle <bundle>` boots a throwaway
  instance, copies `parbake-agent` in over SSH, starts it as the provisioned account, and calls it
  through `Vminitd`. Measured on macOS 27.0.1 host and guest: vsock port 1024 accepted the connection
  20 s after the boot (SSH answered at 10 s); `Getenv` returned the protocol version `1` and
  `/Users/runner`; `Sync` succeeded; `Umount` returned `unimplemented`. swift-nio's vsock transport
  listens on `AF_VSOCK` in a macOS guest without root. The debug agent binary is 78 MB.
- **V-2 — passed at the agent, 2026-10-18:** through `Vminitd`, `/bin/sh -c 'echo out; echo err >&2;
  exit 3'` delivered `out` on stdout and `err` on stderr separately and `WaitProcess` returned 3
  (`parbake agent-probe`). The same run passed stdin through `cat`, got 143 for `tail -f /dev/null`
  after `KillProcess` SIGTERM, and refused uid 0 from a non-root agent. Through `container exec`
  this waits for C-005.
- **V-3:** `container exec -it mac1 zsh` gets a PTY; a terminal resize reaches `stty size`.
- **V-4:** `container exec mac1 security list-keychains` as the guest account lists its login keychain;
  `xcrun simctl list` answers.
- **V-5:** `container run -d` returns only after readiness; with the agent stopped it fails after the
  timeout and the guest is stopped.
- **V-6:** `container stop` with the agent shuts the guest down with exit 0 and no SSH connection in
  the log.

## Resolved Questions

Decided by Christian Semmelmann, 2026-10-18.

1. **Protocol:** the SandboxContext subset over vsock — ADR 0006, Accepted.
2. **Readiness:** gated inside `startProcess` of the init process (C-005). A separate signal, such as
   `container`'s health checks, may come later as an addition. Chosen because a caller then needs
   nothing new and `container run -d` means "ready", as it means "process started" for Linux.
3. **Default user of `container exec`:** the provisioned account, root only with `--user root`
   (C-005, user mapping). Chosen because a macOS job needs the account's session for the Keychain,
   signing and simulators, and root has none. Verified in apple/container: without `--user`, exec
   sends the init process's user, `.id(uid: 0, gid: 0)`; `--user root` sends `.raw("root")`.
4. **Delivery:** the agent is built, signed and installed with the plugin and copied into the guest
   by provisioning and `parbake agent install` (C-006). Chosen for one build and one protocol
   version on both sides; a virtiofs-delivered agent at every boot stays a possible successor once
   automount before login is measured.

## Open Questions

- None.

## Approval

- [ ] Decider: Christian Semmelmann
