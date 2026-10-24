<!-- doc_type: explanation -->
# ADR: One process runner and one error type per module

## Metadata

**Status:** Accepted
**Date:** 2026-10-23
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** architecture, errors, process
**Supersedes:** N/A
**Superseded By:** N/A
**Related:** [ADR 0009](adr_0009_module_boundaries_and_one_version_target.md),
[ADR 0003](adr_0003_controlled_shutdown_over_ssh.md)

## Context

The code spawned child processes at six `Process()` sites and threw errors of many types.

| Site | Module |
|------|--------|
| `GuestShell` | `RuntimeMacOS` |
| `GuestCredentials` | `RuntimeMacOS` |
| `RestoreImages` | `RuntimeMacOS` |
| `Provision` | `parbake` |
| `GuestProcess` | `parbake-agent` |
| `GUISession` | `parbake-agent` |

Each site wired its own pipes. A child that wrote more than a pipe buffer while its input was
still unread could deadlock the caller. None of the sites bounded the wait. `RuntimeMacOS` threw
`RuntimeFailure`, `BundlePathError`, `IncompatibleOverlayError`, `GuestAgent.VersionMismatch`,
`GuestAgent.ProcessLost` and `ContainerizationError` built at many sites.

The shutdown commands existed as five ssh strings, two agent argument lists and four stop ladders.
The wait for a reachable guest existed as several hand-written loops.

[ADR 0009](adr_0009_module_boundaries_and_one_version_target.md) fixes the module boundaries.
`parbake-agent` runs in the guest and does not import `RuntimeMacOS`. `ParbakeVersion` is the
only target shared by host and guest.

## Decision Drivers

- A child process is run, timed out and cancelled in one place.
- A reader finds one error type in each module and one place where it changes type.
- Exit codes, XPC error codes and user-visible messages stay byte-identical.
- Module boundaries from ADR 0009 stay as they are.
- A new package dependency is small, pinned by `Package.resolved` and used by as few targets as possible.

## Considered Options

### Decision 1: Where child processes are run

#### Option 1: One helper per binary (chosen)

| Pros | Cons |
|------|------|
| Respects ADR 0009: the agent does not import `RuntimeMacOS` | Two helpers instead of one |
| Each helper stays small and fits its callers | The two share no code |

#### Option 2: One shared leaf target for both binaries

| Pros | Cons |
|------|------|
| A single implementation | Adds a second shared leaf, which amends ADR 0009 ("`ParbakeVersion` is the shared leaf") |
| | Pulls host-only needs such as timeouts into the guest binary |

#### Option 3: Leave each site with its own `Process()`

| Pros | Cons |
|------|------|
| No change | The pipe, timeout and cancellation hazards stay in six places |

### Decision 2: Which API the helper uses

#### Option 1: Hand-write the runner on `Foundation.Process`

| Pros | Cons |
|------|------|
| No new dependency | The helper owns pipe draining, signals and reaping itself |
| One swap point per binary | A synchronous wait for the child is easy to write and blocks a thread |

#### Option 2: Adopt swift-subprocess (chosen)

| Pros | Cons |
|------|------|
| Follows SW-IO-05 of the Swift quality rule | Adds a package to `Package.resolved` |
| Drains pipes and spawns without a hand-written reaper | Still needs a thin wrapper for the timeout, the input pipe and the status mapping |
| Spawns on `posix_spawn` with structured cancellation | Its `run` starts an unstructured task on the global pool, so the runner can only be async |

#### Option 3: Call `posix_spawn` directly

| Pros | Cons |
|------|------|
| No Foundation process type | The project owns more low-level code than a wrapper needs |

### Decision 3: How errors are typed

#### Option 1: One `Error` type per module, converted at the boundary (chosen)

| Pros | Cons |
|------|------|
| A reader knows the type to match in each module | The enum grows by every old type's cases |
| Each conversion is a single function | Callers that matched an old type change |

#### Option 2: Keep a type per concern

| Pros | Cons |
|------|------|
| No churn | Callers match several types and several `ContainerizationError` codes |

#### Option 3: Use `ContainerizationError` everywhere

| Pros | Cons |
|------|------|
| One type the plugin already throws | The pure library and the CLIs then depend on the XPC error shape |
| | `parbake` needs its own exit-code mapping on top |

### Decision 4: Where the shutdown and wait logic lives

#### Option 1: Strings and ladder in `RuntimeMacOS`; the plugin keeps its state changes (chosen)

| Pros | Cons |
|------|------|
| One set of commands and one ladder | The plugin actor calls into the ladder |
| State transitions stay inside the actor that owns them | |

#### Option 2: Move the whole stop path, state included, into the library

| Pros | Cons |
|------|------|
| One owner of the whole path | The library would hold the plugin's container state |

#### Option 3: Leave four ladders

| Pros | Cons |
|------|------|
| No change | The four copies drift, as the ssh and agent paths already did |

## Decision Outcome

### Process runners

`HostProcess` in `RuntimeMacOS` serves the four host sites: `GuestShell`, `GuestCredentials`,
`RestoreImages` and `parbake` provisioning. It captures, inherits or discards each stream, takes
optional input and an optional environment, and bounds the run with a timeout and with task
cancellation. It drains captured pipes concurrently and ends a child with SIGTERM and then SIGKILL
after two seconds. A spawn failure throws `RuntimeFailure.internalError`. `GuestShell.run` catches
it and keeps a status of `-1`, so its callers do not change.

`parbake-agent` gets `AgentCommand`, a helper inside its own module. It serves `GuestProcess` and
`GUISession`. It runs a program for at most 30 seconds, then sends SIGTERM and, two seconds later,
SIGKILL, and returns the status the child ended with.

Both runners spawn through swift-subprocess, a package dependency
(`https://github.com/swiftlang/swift-subprocess`, from 1.0.2, with its traits off). Its `Subprocess`
product is linked into `RuntimeMacOS` and `parbake-agent` only. `parbake-agent` uses it directly
because [ADR 0009](adr_0009_module_boundaries_and_one_version_target.md) forbids it from importing
`RuntimeMacOS`. `Foundation.Process` appears in neither file.

The runners are async only. `Subprocess.run` starts an unstructured task on the global pool, so a
synchronous bridge that blocks pool threads while waiting for it exhausts the pool and hangs.

The wrapper keeps the semantics the project owns:

- The timeout and the SIGTERM then SIGKILL ladder run on `ContinuousClock`.
- A normal exit reports its code masked with `0xFF`, because Darwin reports more than eight bits
  of the value passed to `exit()`. A death by signal `n` reports `128 + n`.
- Input goes through a pipe the wrapper creates with `F_SETNOSIGPIPE`, written on its own thread. A
  child that exits without reading its input then neither kills the caller with SIGPIPE nor fails
  the run.
- A cancelled task stops the child the same way and returns the output collected so far.

### Errors

`RuntimeFailure` is the only `Error` type that `RuntimeMacOS` throws. `ProbeError` also conforms to
`Error`, but it is never thrown. It is the failure payload of the `Result` that a `reach` closure
returns to `GuestReachability.waitForSSH`, with the text to show for a failed attempt.
`BundlePathError`, `IncompatibleOverlayError`, `GuestAgent.VersionMismatch`,
`GuestAgent.ProcessLost` and every constructed `ContainerizationError` become cases of `RuntimeFailure`, with unchanged text and codes.
`processLost` stores the cause as a `String`, so `RuntimeFailure` stays `Equatable` and `Sendable`.

| Module | Type | Boundary |
|--------|------|----------|
| `RuntimeMacOS` | `RuntimeFailure` only | none |
| `container-runtime-macos` | throws `ContainerizationError` | `RuntimeLifecycle.containerizationError(from:)` converts a `RuntimeFailure` and passes any other error through |
| `parbake` | `ParbakeError`, which wraps `RuntimeFailure` | `ParbakeExit.code` maps to exit codes 64, 66, 69, 75, 3 and 1 |
| `parbake-agent` | `AgentError` | `AgentError.rpcError` builds the `RPCError` in one mapping |

ArgumentParser's `ValidationError` stays for usage errors, which exit 64, because ArgumentParser
requires it.

### Shutdown and waiting

`GuestCommands` holds the shutdown strings and argument lists, with the same bytes as before.
`GuestShutdown` holds the ladder: request, wait, power button, wait, force. The plugin's actor keeps
its state transitions and calls the ladder.

### Where the earlier list met the code

- **Wait loops.** `Setup` and `Layer` contain no wait-for-guest loop, so nothing changes there.
  `GuestReachability.waitForSSH` serves provisioning, agent installation and the agent probe.
  `GuestReachability.poll` serves the agent dial, the readiness wait and the aux-storage lock retry.
  The stop wait of agent setup moves to `GuestShutdown`.
- **Poll intervals.** `poll` probes at once, then once every interval, with a last probe at the
  deadline, and it never sleeps past the deadline. `waitForSSH` polls every 3 s, the agent dial every
  1 s and the aux-storage lock retry every 2 s. Provisioning keeps its last-ssh-error output
  through the `onProbeError` callback.
- **Stop ladder.** The strings and the ladder live in `GuestCommands` and `GuestShutdown`. The
  state changes stay in the plugin actor, as ADR 0003 describes the ssh shutdown it uses.

## Rationale

One helper per binary removes the repeated pipe code without touching ADR 0009. A third leaf target
would be the only way to share one implementation, and it would amend that ADR for a small gain.

swift-subprocess replaces hand-written pipe draining, spawning and reaping with a library that
covers the hazards SW-IO-05 names. The two thin wrappers keep only what the library does not
decide, and they confine the dependency to the two targets that spawn children.

One error type per module lets a caller match on one enum. The conversions sit at the module
edges, where the plugin must throw the type that apple/container's client decodes and `parbake`
must produce an exit code.

## Consequences

**Positive:**

- A child process is timed out, cancelled and drained the same way everywhere on the host.
- `RuntimeFailure` is the only type to match in `RuntimeMacOS`.
- The shutdown commands, the ladder and the guest wait each have one definition.

**Negative:**

- The host and the agent keep two runners that share no code.
- The package depends on swift-subprocess, and `Package.resolved` pins it.
- The project still owns the wrapper semantics. These are the timeout, the status mapping with the
  `0xFF` mask and `128 + n`, the input writer without SIGPIPE, and cancellation that returns output.
- The runners are async only, so every caller of a child process is async.
- `RuntimeFailure` is large.
- A grandchild that holds a child's pipes survives the timeout, because the timeout ends the child
  and not a process group.

## NFR coverage

- **Reliability:** a hung or chatty child no longer blocks its caller.
- **Operability:** every user-visible message and exit code is unchanged and pinned by tests.
- **Security:** one pinned dependency enters the supply chain, in the two targets that spawn children.

## Implementation

- [x] Add `HostProcess` and `AgentCommand`, and move the six `Process()` sites to them.
- [x] Add swift-subprocess to `Package.swift` and `Package.resolved`, linked into `RuntimeMacOS` and `parbake-agent` only.
- [x] Fold the `RuntimeMacOS` error types into `RuntimeFailure` and convert at the module edges.
- [x] Add `GuestCommands`, `GuestReachability` and `GuestShutdown`, and route the callers through them.

## Validation

- [x] `Foundation.Process` appears in no file under `Sources/`.
- [x] `ContainerizationError(` is constructed in `RuntimeMacOS` only inside `RuntimeLifecycle`.
- [x] A golden table pins the text and code of every replaced error.
- [x] `scripts/lint-boundaries.sh` passes.

## Links

- [ADR 0009](adr_0009_module_boundaries_and_one_version_target.md), module boundaries
- [ADR 0003](adr_0003_controlled_shutdown_over_ssh.md), controlled shutdown over ssh

## Changelog

- 2026-10-23: Initial version.
- 2026-10-24: Both runners spawn through swift-subprocess, and the decision and its consequences follow the code.
