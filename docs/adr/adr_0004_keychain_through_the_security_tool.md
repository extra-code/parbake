# ADR: The guest password lives in the keychain and is reached only through `/usr/bin/security`

## Metadata

**Status:** Accepted
**Date:** 2026-10-18
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** security, credentials
**Supersedes:** N/A
**Superseded By:** N/A

## Context

`parbake provision --keychain` keeps the guest account's password in the login keychain so nobody
types it on a CI host. The binaries are ad-hoc signed, so every build has a new code identity.

Measured on this host, 2026-10-18:

- An item created with `SecItemAdd` by one build of `parbake` prompted when a rebuilt `parbake`
  read it; provisioning waited on the dialog.
- An item created with `SecItemAdd` and an access list admitting every application still prompted
  for another binary.
- An item created by `security add-generic-password -A` was read by `security` without a prompt;
  `security add-generic-password -U` on that item prompted; deleting and adding it did not.
- Tests that read and deleted items from the ad-hoc signed test binary raised many dialogs.

The user chose access for every application over a stable signing identity for now.

## Decision Drivers

- No keychain dialog after a rebuild or update, on a host where nobody answers one.
- The password never appears in an argument list.

## Considered Options

### Option 1: Security framework calls from the binary

| Pros | Cons |
|------|------|
| No subprocess | Every new ad-hoc identity prompts; open access lists do not help |

### Option 2: Stable signing identity (Developer ID)

| Pros | Cons |
|------|------|
| Access survives updates, narrow access | Needs a certificate and a signing setup on every build host |

### Option 3: Every access through `security -i`, items created with `-A` (chosen)

| Pros | Cons |
|------|------|
| The item belongs to a stable Apple-signed tool; no prompt after rebuilds | Every process of the user can read the item |
| Commands on stdin, no password in argv | A subprocess per access |

## Decision Outcome

**Option 3.** `GuestCredentials` reads, adds and deletes through `security -i`, whose exit status is the
command's. `store` deletes a stored item and adds it again with `-A`; it never updates in place.
Passwords cannot contain a newline.

### Consequences

**Positive:**

- No dialog from provisioning or tests; the keychain tests run in 0.2 s.

**Negative:**

- Any process of the host user reads the guest password; acceptable for a dedicated CI user.
- An item created by an earlier build prompts once when `security` first reads it.

## Validation

- [x] `GuestCredentialsTests`: round trip, replace, remove, and `security` reading the item without
      a prompt, each in milliseconds.
- [x] On this host: provisioning `runner` with `--keychain` without a dialog.

## Links

- Code: `Sources/RuntimeMacOS/GuestCredentials.swift`

## Changelog

- 2026-10-18 — Initial version.
