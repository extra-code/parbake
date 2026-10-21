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
  `VMADDR_CID_HOST` (2); processes inside the guest cannot reach it. grpc-swift reports no peer for a
  vsock connection, so the agent accepts vsock connections itself, checks the CID, and relays each
  admitted connection to its gRPC server on a Unix socket, `/var/run/parbake-agent.sock` as root
  (mode 0700), or in the temporary directory otherwise.
- Serves `SandboxContext.SimpleServiceProtocol`. RPCs outside C-002 to C-004 and C-007 throw
  `RPCError(code: .unimplemented)`.
- Logs to standard error, which the LaunchDaemon writes to `/var/log/parbake-agent.log`.

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
  `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`, `TMPDIR` the account's own temporary directory;
  `process.env` overrides them.
- Process IDs are unique per agent run; a second `CreateProcess` with a known ID fails with
  `ALREADY_EXISTS`.
- Every process starts in a process group of its own (with a terminal: a session of its own), with
  default signal dispositions and an empty signal mask, and inherits no descriptor but 0 to 2. An
  ignored signal survives `exec`: without the reset, a process inherits whatever the agent's
  launcher ignored, and an inherited ignored SIGTERM never stops it.
- An agent that does not run as root starts processes only as its own account and refuses any other
  with `FAILED_PRECONDITION`.

### C-003 — Standard streams

- For each port in the request, the agent connects to `VMADDR_CID_HOST` on that port before
  `StartProcess` returns; a failed connection fails `StartProcess`.
- Without a terminal: stdin, stdout and stderr are separate pipes copied to and from their
  connections.
- With a terminal: one PTY (`posix_openpt`) that is the process's controlling terminal, so Ctrl-C
  sends SIGINT and a shell gets job control; its output goes to the stdout connection, stdin feeds
  it, no stderr connection is used. `process.consoleSize` and `ResizeProcess` set the size
  (`TIOCSWINSZ`); `TERM` defaults to `xterm`.
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
  `Getenv("CONTAINER_RUNTIME_MACOS_AGENT")` returns its version line, `<protocol>` optionally followed
  by a space and informational fields, for example `1` or `1 0.52.0`. The runtime reads only the first
  field. The protocol number changes only when this spec changes the wire contract.
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
  `["/sbin/shutdown", "-h", "now"]` as root through the agent. An agent that does not run as root
  refuses that with `FAILED_PRECONDITION`, and the runtime then starts
  `["/usr/bin/sudo", "-n", "/sbin/shutdown", "-h", "now"]` as the provisioned account. Exit 0 counts
  as accepted, and so does a connection that ends while the shutdown runs. When neither attempt is
  accepted, ADR 0003 applies.
- **No agent:** a call to an agent that does not answer fails with a message that names
  `parbake agent install`.
- **Signals** arrive as names or numbers (`SIGTERM`, `TERM`, `15`) and map to Darwin's numbers, which
  differ from Linux for several signals (SIGUSR1 is 30).

### C-006 — Installation and update

- `parbake provision` copies the agent binary to `/tmp/parbake-agent.staged` in an SSH connection
  of its own, then the preparation SSH session installs it as root: the binary to
  `/usr/local/libexec/parbake-agent`, the property list to
  `/Library/LaunchDaemons/container-runtime-macos.agent.plist`, loaded with
  `launchctl bootstrap system`. The guest then stays up: provisioning waits for `Getenv` over vsock
  (at most 120 s), writes the answer into `Agent`, and shuts the guest down through the agent.
  `--no-agent` skips all of it; `--agent <path>` picks another build.
- `parbake agent install --bundle <path>` boots a provisioned bundle once, copies the agent from
  this build in over SSH with `GuestKey`, installs it with the account's password (from the keychain
  with `--keychain`, else standard input), updates `Agent` the same way, and shuts the guest down
  through the agent. It is the update path for existing bundles and after a protocol change. It
  writes to the bundle's disk image, so containers made from the bundle before must be removed.
- `task install` puts `parbake` and `parbake-agent` next to the plugin, and both commands take the
  agent from the directory of `parbake` by default.
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
- **V-2 — passed, at the agent 2026-10-18 and through `container exec` 2026-10-19:** through `Vminitd`, `/bin/sh -c 'echo out; echo err >&2;
  exit 3'` delivered `out` on stdout and `err` on stderr separately and `WaitProcess` returned 3
  (`parbake agent-probe`). The same run passed stdin through `cat`, got 143 for `tail -f /dev/null`
  after `KillProcess` SIGTERM, and refused uid 0 from a non-root agent.
  **Through `container exec`, passed 2026-10-19** with the agent as a LaunchAgent of the provisioned
  account: `container exec mac1 sh -c 'echo out; echo err >&2; exit 3'` printed `out` on stdout, `err`
  on stderr and exited 3; `echo … | container exec -i mac1 cat` echoed the input; without `--user` the
  process ran as `runner` in `/Users/runner`; `--user root` was refused by the non-root agent;
  `container exec mac1 true` took 54 ms. A signal the CLI forwards never reaches the runtime, because
  apple/container's API server drops it ([apple/container#1941](https://github.com/apple/container/issues/1941));
  the agent's own signal path is covered by the run through `Vminitd` above.
- **V-3 — passed 2026-10-21:** `container exec -it mac1 zsh` gets a PTY; a terminal resize reaches
  `stty size`. Measured with an expect script on a provisioned bundle: `tty` named a `/dev/ttys` device with
  `TERM=xterm`; `stty size` showed the initial 24 80 and 40 100 after a resize; Ctrl-C ended
  `sleep 100` with 130 and returned to the prompt; the shell's process group owned the terminal;
  `exit 5` ended `container exec` with 5. The non-terminal checks of V-2 passed again.
- **V-4:** `container exec mac1 security list-keychains` as the guest account lists its login keychain;
  `xcrun simctl list` answers. **Keychain half passed 2026-10-19:** it listed
  `/Users/runner/Library/Keychains/login.keychain-db`. The simulator half needs a bundle with Xcode.
- **V-5 — passed 2026-10-19:** `container run -d` returns only after readiness; with the agent
  stopped it fails after the timeout and the guest is stopped. Measured: `container start` returned
  17 s after the boot began, once the agent answered, and an `exec` right after it succeeded. A
  container with `runtime-macos.readiness-timeout=30`, an `Agent` file and no agent failed after
  30 s; the guest stopped with 137 and the container showed `stopped`.
- **V-6 — passed 2026-10-19:** `container stop` with the agent shuts the guest down with exit 0 and
  no SSH connection in the log. Measured with a non-root agent: root refused, `sudo -n` as `runner`
  accepted, exit 0 after 1.4 s.

- **C-006 — passed 2026-10-19:** `parbake agent install --bundle ~/VM4.bundle --keychain` on an APFS
  clone of a provisioned bundle took 30 s with no keychain dialog; the agent answered over vsock and
  shut the guest down as root. A container from the bundle started with the readiness gate (23 s),
  and through the root agent: `exec` ran as `runner` in its `Aqua` session, wrote and read a generic
  password in its login keychain, `--user root` ran as root, stop took 6 s with exit 0, and the agent
  answered again after the next boot. Inside the guest, a vsock connection to port 1024 from CID 3
  was refused and logged, and `runner` got `Permission denied` on the agent's Unix socket.
  `provision` with the agent ran only as unit tests (scripts parse, property list valid): a fresh
  bundle did not fit on this host's free disk.

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
