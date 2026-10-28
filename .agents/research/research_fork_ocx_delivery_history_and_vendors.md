# Research: Repo history and common practice for shipping services

## Metadata

**Date:** 2026-10-26
**Domain:** packaging
**Triggered by:** `.agents/discussions/fork-container-ocx-delivery.md`, the repo archaeology and
vendor lanes
**Expires:** 2027-04-26

## Direct Answer

The repo records the one-apiserver constraint only in the header of `scripts/dev-env.sh`. No ADR,
plan or retro row discusses running stock and fork side by side, or a channel for shipping
binaries. macOS virtualization tools ship in one of two ways:
- a Developer-ID-signed, notarised pkg or app;
- a package-manager recipe that builds from source and signs ad hoc.

## Repo history

- `scripts/dev-env.sh:5-10` has carried this header since commit ce1a603: "Both builds register
  the same launchd service, so only one runs at a time". `AGENTS.md:99` and `README.md:60-62,249-251`
  repeat it.
- `docs/signing.md` says the plugin and the container services must share a signing domain. A
  team-signed plugin against an ad-hoc network service fails with "failed to start the DHCP
  interface on the vmnet network, status 1001". Ledger row
  `.agents/retro/ledger/project-plugin-signing-identity.json` records it.
- `docs/signing.md:23` says "Parbake ships no binaries, so it uses no Developer ID".
- ADR 0013 does not choose a binary distribution channel. Open decision 3 in
  `.agents/plans/plan_macos_runtime.md` asks whether distributed builds get a Developer ID. Open
  decision 2 is about bundle images, not binaries.
- `parbake setup --bundle` already exists. It boots a bundle for the Setup Assistant
  (`README.md:180`), so a new service command needs a different name.
- ADR 0002, 0004 and 0010 record that an ad-hoc build changes its identity on every rebuild. That
  affects Local Network and the keychain ACL. ADR 0006 avoids Local Network through vsock.

## Common practice

Coverage is partial, and the details below are not verified per tool.

- **Source-building recipes:** a package-manager recipe for apple/container builds from source
  and signs everything ad hoc. Only two plugins carry `com.apple.security.virtualization`.
- **Official apple/container .pkg:** it installs into `/usr/local`, and the binaries inside are
  signed ad hoc (apple/container#1682).
- **Notarised pkg or app:** tools that ship this way sign with a Developer ID.
- **VM images in OCI registries:** one tool distributes its VM images through an OCI registry.
- **Bridged networking:** it needs `com.apple.vm.networking`, a restricted entitlement that only
  an approved provisioning profile grants. Builds without such a profile disable bridged mode.

## macOS rules

- A restricted entitlement needs a provisioning profile. `com.apple.security.virtualization` is not
  restricted, and works when signed ad hoc.
- Since macOS 13, registering a launch item can show a "can run in the background" notification
  and a Login Items entry (developer.apple.com/forums/thread/756846). Whether a plist loaded by
  `launchctl bootstrap` triggers it is unverified.

## negative

- No primary source was found for the entitlements or launchd labels of other macOS VM tools.

## leads

- Check whether `container system start` triggers the Background Task Management notification on a
  clean macOS 27 user.
