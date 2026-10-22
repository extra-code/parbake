<!-- doc_type: explanation -->
# ADR: Keychain access to the guest password follows the signing identity

## Metadata

**Status:** Accepted
**Date:** 2026-10-22
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** security, credentials, signing
**Supersedes:** N/A
**Superseded By:** N/A
**Amends:** [ADR 0004](adr_0004_keychain_through_the_security_tool.md)

## Context

[ADR 0004](adr_0004_keychain_through_the_security_tool.md) stores the guest password with `-A`.
Every process of the host user can then read it. ADR 0004 chose this because each ad-hoc build gets a
new code identity, and the Security framework prompted after every rebuild.

An Apple Development identity gives every build the same designated requirement. The readers of the
item are `parbake` subcommands only; the plugin never reads it. `security -T <binary>` does not fit,
because reads through `/usr/bin/security` would need that tool on the list too.

Validation used Apple silicon and an Apple Development identity. Personal certificate and team
identifiers, exact OS build and host-specific details are omitted.

- `parbake create --keychain` stored the password in-process and finished with no dialog and no
  ad-hoc warning.
- A rebuilt `parbake` with a different CDHash, the same team ID and the same designated requirement
  ran `parbake agent install --keychain`. It read the password with no dialog.
- `security find-generic-password -s container-runtime-macos.guest -a runner -w` printed nothing.
  It waited on a dialog until the test timeout ended it.

## Decision Drivers

- No keychain dialog after a rebuild or update, on a host where nobody answers one.
- Only Parbake reads the guest password when the build allows it.
- Ad-hoc builds, the default for local work and CI, keep working.

## Considered Options

### Option 1: Keep `-A` for every build

| Pros | Cons |
|------|------|
| One code path | Every process of the user reads the password, even with a stable identity |

### Option 2: `security -T` with the signed binary

| Pros | Cons |
|------|------|
| Keeps the subprocess path | `/usr/bin/security` does the reads, so it must be on the list too, which admits everyone again |

### Option 3: The access follows the signing identity (chosen)

| Pros | Cons |
|------|------|
| A team-signed `parbake` owns the item; other processes get a dialog | Two code paths |
| Ad-hoc builds still run unattended | Ad-hoc builds keep ADR 0004's exposure |

## Decision Outcome

**Option 3.** `KeychainAccess.for(_:)` maps the identity of the running process to an access mode.

- A team identity gets `creatorOnly`. `parbake` creates, reads and deletes the item through the Security
  framework in its own process. `SecItemAdd`'s default access list admits the creating, signed binary.
- An ad-hoc identity gets `anyApplication`. Access goes through `security -i` with `-A`, as in ADR 0004.
  `parbake create --keychain` prints a warning that names the exposure.

The identity check reads the code signature of the running process (`SigningIdentity.ofCurrentProcess()`).
A signature with a `TeamIdentifier` is a team identity; anything else is ad hoc.
`KeychainAccess.restrictsWithStableIdentity` turns the team mapping off when it is false.

### Consequences

**Positive:**

- With a stable identity, other processes of the CI user cannot read the password silently.
- Rebuilds with the same identity read the item with no dialog.

**Negative:**

- An item created by an ad-hoc build stays readable by every application until it is created again.
- A build signed with a different team prompts when it reads an item from an earlier team build.
- A team-signed plugin cannot start vmnet DHCP (status 1001, "different security domains"), so the plugin stays ad hoc. `PARBAKE_CODESIGN_IDENTITY` signs `parbake` alone.

## Validation

- [x] `parbake create --keychain` and a rebuilt `parbake agent install --keychain` both complete without a dialog.
- [x] `security find-generic-password -w` does not return the password without a dialog.
- [x] `GuestProvisioningTests` covers the mapping, the ad-hoc warning and the `security` path.
  The in-process path runs only on the host, because the test binary is signed ad hoc.

## Links

- [ADR 0004](adr_0004_keychain_through_the_security_tool.md)
- [Signing guide](../signing.md)
- Code: `Sources/RuntimeMacOS/SigningIdentity.swift`, `Sources/RuntimeMacOS/GuestCredentials.swift`

## Changelog

- 2026-10-22: Initial version.
