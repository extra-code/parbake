<!-- doc_type: explanation -->
# ADR: The runtime shuts a provisioned guest down over SSH

## Metadata

**Status:** Accepted
**Date:** 2026-10-18
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** lifecycle, security
**Supersedes:** N/A
**Superseded By:** N/A

## Context

`container stop` asked the guest to shut down with `VZVirtualMachine.requestStop()`, a press of the
power button, and stopped it forcibly once the timeout passed. `container stop`'s default timeout is
5 s.

Validation found that a provisioned macOS guest can ignore `requestStop` and require a forced stop
(exit 137). A guest given `sudo -n /sbin/shutdown -h now` over SSH shut down with exit 0. The guest's
sshd ends as soon as `shutdown` runs, so output printed after it does not arrive.

A controlled shutdown is preferred over a forced stop.

## Decision Drivers

- A guest's own shutdown is the normal end. A forced stop is the fallback.
- No password at stop time, and none stored for the runtime.
- A guest without a running agent still stops in a controlled way.

## Considered Options

### Option 1: Power-button request only

| Pros | Cons |
|------|------|
| No credentials | Ignored by a logged-in guest at times; the 5 s default forces a stop anyway |

### Option 2: SSH with the account password from the keychain

| Pros | Cons |
|------|------|
| No key material in the bundle | Password per stop, keychain access from the runtime |

### Option 3: SSH with a per-bundle guest key and passwordless `/sbin/shutdown` (chosen)

| Pros | Cons |
|------|------|
| No password at stop time | The bundle carries a private key; whoever reads the bundle logs in as the account |
| Shutdown accepted is known before the guest goes down | Needs an address and a running sshd |

## Decision Outcome

**Option 3.** Provisioning creates `GuestKey` in the bundle and adds its public key to the account's
`authorized_keys`. It writes `/etc/sudoers.d/parbake`, which allows `/sbin/shutdown` without a password,
in the same SSH session as the other preparation. `container stop`, and `container kill` with any
signal but SIGKILL, run `sudo -n -l /sbin/shutdown && echo <accepted> && sudo -n /sbin/shutdown -h now`
with that key. An accepted shutdown gets at least 60 s whatever `--time` says. A guest without
`GuestKey`, without an address or refusing gets the power-button request. Either way the guest is
stopped forcibly once the wait passes.

**Amended 2026-10-19:** with the guest agent, the runtime first runs `/sbin/shutdown -h now` through
the agent. It runs as root, or with `sudo -n` as the provisioned account when the agent does not run as
root, using the same sudoers rule. SSH and then the power-button request remain the fallbacks, in
that order. The same 60 s minimum applies.

### Consequences

**Positive:**

- Accepted shutdowns end with exit 0.
- `MacOSVirtualMachine.wait(timeout:)` returns as soon as the guest stops, so the reply to `stop`
  precedes the API server's exit handling.

**Negative:**

- `--time` below 60 s does not shorten an accepted shutdown.
- The guest shutdown request gets min(stop timeout, 60 s). `container stop` passes 5 s by default, so a
  short stop timeout falls back to the power-button request and then a forced stop.
- Reading the bundle gives a login to the guest account. The disk image already gives everything.

**Risks:**

- A guest that accepts and then hangs in shutdown is stopped forcibly after 60 s.

## Validation

- [x] `container stop` with the default timeout exits 0 without an XPC error.
- [x] `GuestPreparationTests`: the script parses, carries keys and password verbatim, ends with the
      shutdown, `--tidy` is optional.
- [x] Shutdown through the vsock guest agent first: `container stop` with an agent in the guest
      exits 0 without an SSH connection in the log.

## Links

- Code: `Sources/RuntimeMacOS/GuestPreparation.swift`, `Sources/container-runtime-macos/RuntimeService.swift`

## Changelog

- 2026-10-18: Initial version.
- 2026-10-19: Shutdown through the guest agent first, SSH as the fallback.
