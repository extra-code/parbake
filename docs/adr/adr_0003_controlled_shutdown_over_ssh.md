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

Measured on this host, 2026-10-18: a provisioned macOS 27 guest ignored `requestStop` for 120 s and was
stopped forcibly (exit 137); in later runs the same request shut a guest down in 6 s. A guest given
`sudo -n /sbin/shutdown -h now` over SSH was off in 6 s, exit 0. The guest's sshd ends as soon as
`shutdown` runs, so output printed after it does not arrive.

The user prefers a controlled shutdown over a forced stop.

## Decision Drivers

- A guest's own shutdown is the normal end; a forced stop is the fallback.
- No password at stop time, and none stored for the runtime.
- No guest agent exists yet.

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
| Shutdown accepted is known before the guest goes down | Depends on SSH until a vsock agent replaces it |

## Decision Outcome

**Option 3.** Provisioning creates `GuestKey` in the bundle, adds its public key to the account's
`authorized_keys` and writes `/etc/sudoers.d/parbake` allowing `/sbin/shutdown` without a password,
in the same SSH session as the other preparation. `container stop`, and `container kill` with any
signal but SIGKILL, run `sudo -n -l /sbin/shutdown && echo <accepted> && sudo -n /sbin/shutdown -h now`
with that key. An accepted shutdown gets at least 60 s whatever `--time` says; a guest without
`GuestKey`, without an address or refusing gets the power-button request. Either way the guest is
stopped forcibly once the wait passes.

**Amended 2026-10-19:** with the guest agent, the runtime first runs `/sbin/shutdown -h now` through
the agent: as root, or with `sudo -n` as the provisioned account when the agent does not run as
root, using the same sudoers rule. SSH and then the power-button request remain the fallbacks, in
that order. The same 60 s minimum applies.

### Consequences

**Positive:**

- Stops end with exit 0 in about 6 s.
- `MacOSVirtualMachine.wait(timeout:)` returns as soon as the guest stops, so the reply to `stop`
  precedes the API server's exit handling.

**Negative:**

- `--time` below 60 s does not shorten an accepted shutdown.
- Reading the bundle gives a login to the guest account; the disk image already gives everything.

**Risks:**

- A guest that accepts and then hangs in shutdown is stopped forcibly after 60 s.

## Validation

- [x] On this host: `container stop` with the default timeout, twice in a row, exit 0, no XPC error.
- [x] `GuestPreparationTests`: the script parses, carries keys and password verbatim, ends with the
      shutdown, `--tidy` is optional.
- [x] Shutdown through the vsock guest agent first: `container stop` with an agent in the guest,
      exit 0 in 1.4 s, no SSH connection in the log (2026-10-19).

## Links

- Code: `Sources/RuntimeMacOS/GuestPreparation.swift`, `Sources/container-runtime-macos/RuntimeService.swift`

## Changelog

- 2026-10-18 — Initial version.
- 2026-10-19 — Shutdown through the guest agent first, SSH as the fallback.
