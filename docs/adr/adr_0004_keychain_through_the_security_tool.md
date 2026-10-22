<!-- doc_type: explanation -->
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
**Amended By:** [ADR 0010](adr_0010_keychain_access_follows_the_signing_identity.md)

## Context

`parbake provision --keychain` keeps the guest account's password in the login keychain so nobody
types it on a CI host. The binaries are ad-hoc signed, so every build has a new code identity.

Validation found:

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

- Provisioning and tests complete without a dialog.

**Negative:**

- Any process of the host user reads the guest password; acceptable for a dedicated CI user.
- An item created by an earlier build prompts once when `security` first reads it.

## Validation

- [x] `GuestCredentialsTests`: round trip, replace, remove, and `security` reading the item without
      a prompt.
- [x] Host integration validation: provisioning a guest account with `--keychain` without a dialog.

## Links

- Code: `Sources/RuntimeMacOS/GuestCredentials.swift`
- [ADR 0010](adr_0010_keychain_access_follows_the_signing_identity.md): a build with a stable identity keeps the item for itself

## Changelog

- 2026-10-18 — Initial version.
- 2026-10-22 — Amended by ADR 0010: this decision applies to ad-hoc builds.
