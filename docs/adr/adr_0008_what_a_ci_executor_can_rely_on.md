<!-- doc_type: explanation -->
# ADR: What a CI executor can rely on: guest limit, failures and writable paths

## Metadata

**Status:** Accepted
**Date:** 2026-10-21
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** ci, virtualization, process
**Supersedes:** N/A
**Superseded By:** N/A

## Context

A CI executor runs a macOS job in three calls: `container run -d` from a bundle, `container exec`
for the job, and `container rm -f`. It needs to know:

- How many macOS guests a host runs, and who refuses one too many.
- Whether a failure came from the job or from the guest, so it can retry an infrastructure failure
  and report a job failure.
- Where the job may write.

`container run -d` returns only once the guest agent answers, and fails with the guest stopped when
it does not ([spec_guest_agent](../specs/spec_guest_agent.md), V-5).

Validation with two running guests from one bundle found:

- A third `container run` failed with Virtualization.framework's `VZErrorDomain` code 6,
  "The maximum supported number of active virtual machines has been reached."
- `container kill` on a guest while `container exec … sleep 100` ran made the exec fail with exit
  status 1, the same status as a job that runs `exit 1`. `container ls` showed the container
  `stopped` right after.
- The provisioned guest account could not write `/usr` or `/System`; its home directory was
  writable, and `TMPDIR` was empty.

## Decision Drivers

- No limit the runtime would have to keep in step with the framework.
- A caller can tell a guest failure from a job failure without parsing messages.
- A job finds writable places where macOS tools look for them.

## Considered Options

### Guest limit

#### Option 1: The runtime counts running guests

| Pros | Cons |
|------|------|
| A refusal before the boot starts | Every container runs its own runtime process, so a count needs shared state |
| | Other Virtualization.framework users on the host are not counted |

#### Option 2: The framework refuses, the runtime names it, the caller schedules (chosen)

| Pros | Cons |
|------|------|
| One authority for the limit, also across other users of the framework | The caller learns of the limit only at start |
| A refusal leaves no guest | |

### Telling a guest failure from a job failure

#### Option 1: Reserved exit codes for guest failures

| Pros | Cons |
|------|------|
| One number to check | A job may exit with any code from 0 to 255, so no code is free |
| | `container exec` turns a failed wait into status 1 itself. A code of its own needs a change in apple/container |

#### Option 2: The exec never reports a guest stop as an exit code, the container state tells (chosen)

| Pros | Cons |
|------|------|
| Works with the CLI as it is | Two calls: the exec, then `container inspect` or `ls` |
| No job code is taken | |

## Decision Outcome

**Guest limit:** at most two macOS guests run per host. Virtualization.framework enforces it. A
start beyond it fails with "this host already runs the two macOS guests Virtualization.framework
allows. Stop one first". Scheduling jobs within the limit is the caller's job.

**Failures:** an executor classifies by these rules.

| Observation | Meaning |
|-------------|---------|
| `container run -d` fails | Guest failure: no boot, or no agent within the readiness timeout. The container is stopped. |
| `container exec` exits and the container still runs | The status is the job's own exit code. |
| `container exec` fails and the container is stopped | Guest failure during the job. The error says "the macOS guest stopped with exit code N while process … ran; the process has no exit code". |
| `container exec` fails and the container still runs | The agent's stream was lost while the guest kept running. The error (`.interrupted`) says "lost the guest agent's stream for process … while the guest kept running; its exit code is unknown". |

A reboot inside a job restarts the guest inside the same VM. Virtualization.framework reports no
reboot, so `exec` ends as lost after about 60 s with the "guest kept running" error. `shutdown -h now`
ends it with the "guest stopped" error.

The guest's own exit code is 0 for a shutdown, 1 for a Virtualization.framework error and 137 for a
forced stop.

**`parbake` exit codes:** `parbake` prints `Error: <message>` to stderr and exits with one of these
codes, so a build script classifies its failures the same way.

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | a runtime failure not listed below |
| 3 | a script run in the guest failed; the message names the script and its exit status |
| 64 | usage: the arguments, the configuration or an input file are invalid |
| 66 | a VM bundle or one of its layout files is missing, or the restore image path does not exist |
| 69 | the host refuses: the two-guest limit is reached, or the keychain is locked or refuses access |
| 75 | try again: the bundle is locked, or the guest gave no DHCP lease, no SSH answer or no agent answer in time |

**Writable paths:** the guest's system volume is sealed. A job writes to the CI account's home
directory and to `TMPDIR`, which the agent sets to the account's own temporary directory. Both are
in the container's overlay and go with the container. A cache that outlives a job needs a shared
host directory, which the runtime does not offer yet.

### Rationale

The framework is the only place that sees every guest on the host, so a count in the runtime could
only disagree with it. An exit code cannot carry the difference between a job and a guest, because
the job owns the whole range. The container state can, and the runtime already reports it.

### Consequences

**Positive:** no shared state between runtime processes. Job exit codes pass through untouched.
Tools that use `TMPDIR` work in `exec`.

**Negative:** an executor makes a second call after a failed exec, and learns the limit only from a
failed start.

**Neutral:** a dedicated exit status for a lost process would need apple/container to pass a
failure kind through `container exec`. This decision does not need it.

## Implementation

- [x] `MacOSVirtualMachine.start` turns `VZError.virtualMachineLimitExceeded` into the message above.
- [x] `RuntimeService.wait` fails with the guest's stop when the agent loses a process and the guest
  stopped.
- [x] The agent sets `TMPDIR` for processes of its own account.
- [x] README limitations name the rules.

## Validation

- [x] A third guest is refused with the message, two keep running.
- [x] `container exec` during a forced stop fails with the guest's stop, and the container is `stopped`.
- [x] `TMPDIR` is set and writable in `exec`, with and without `-t`.
