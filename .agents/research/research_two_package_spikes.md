# Research: Two OCX packages joined by a symlink install root, and the signing domain

## Metadata

**Date:** 2026-10-28
**Domain:** packaging, signing
**Triggered by:** the decision to ship `ocx.sh/extra-code/container` (the fork, ephemeral) and
`ocx.sh/extra-code/parbake` (the plugin, durable) as two packages, and the question whether a later
Apple-signed `container` release can run the ad-hoc-signed plugin.
**Expires:** 2027-04-28

Host: macOS 27 on Apple silicon, stock apple/container 1.5.0 installed in `/usr/local`, the fork at
`0f824548` built by `task package VERSION=0.1.0`. Every run was attended and ended on the stock
services. The spike script and its data stayed outside the repository.

## Direct Answer

- Two packages work without a fork patch. A small directory of symlinks serves as the install root,
  and `container system start --install-root` points the fork's services at it.
- The plugin joins the vmnet network only when it carries the same signature as the services. Ad hoc
  with ad hoc works, and one team with the same team works. A mixed pair fails with "failed to
  start the DHCP interface on the vmnet network, status 1001", in both directions.
- An Apple-signed `container` release with our patches would therefore still not run an
  ad-hoc-signed plugin through Apple's own network service.

## Method

1. Split the package root of `task package` into two OCX packages with `ocx package create`. One
   holds the fork's install root, the other holds the plugin directory. Materialise both with
   `ocx package test -o`.
2. Two symlinks stand in for `ocx package install --link`. That flag links to the package directory,
   whose files sit under `content/`. An earlier test with another package showed this.
3. Build a root of symlinks:
   - `bin` and `libexec/container` link into the container package's `content/`;
   - `libexec/container-plugins` links to a shared directory, which stands in for
     `/usr/local/libexec/container-plugins`;
   - that directory holds `container-runtime-macos`, a link to the plugin package's `content/`.
4. For the team cases, copy the container package and re-sign every Mach-O file with one Apple
   Development identity, keeping its entitlements. The store copy stays untouched.
5. Each run starts the services with `--install-root <root> --app-root <scratch>
   --disable-kernel-install`. It then runs a guest from a home-directory bundle, checks `running`,
   the DHCP address and `exec sw_vers`, and stops and removes the guest.

## Findings

### Package layout

- `ocx package create` accepts both trees.
- It refuses a symlink inside a package that points outside the package root: "symlink … escapes
  the root directory". A package can therefore not link itself to `/usr/local`. The root of symlinks
  has to live outside the store.
- Entitlements survive the split and the re-signing. Only
  `container-runtime-linux`, `container-network-vmnet`, `container-runtime-macos` and `parbake`
  carry `com.apple.security.virtualization`, and no binary carries a restricted entitlement.

### Plugin discovery through the symlink root

- The apiserver logged both plugin directories: the shared directory, after resolving the
  `libexec/container-plugins` link, and `<root>/libexec/container/plugins/`.
- `PluginLoader.findPlugins` follows a plugin entry that is a symlink to a directory.
- launchd records the apiserver `program` as the resolved store path, not the path through the root.
  A docs check on `launchctl print` must expect the store path.

### Signing-domain matrix

| Services | Plugin | Result |
|---|---|---|
| ad hoc | ad hoc | guest `running` after 30 s, DHCP address, `exec sw_vers` answers |
| one team | ad hoc | status 1001 when the guest attaches to the network (reproduced on a second run) |
| one team | the same team | guest `running` after 33 s, DHCP address, `exec sw_vers` answers |
| ad hoc | one team | status 1001 (recorded earlier in `docs/signing.md`) |

Loading, registering and launching the plugin succeeded in every case. Only the network attach
failed. The services created the vmnet network in every case.

### First start of freshly signed binaries

The first team run waited about four minutes before the runtime plugin registered. Gatekeeper had
assessed each binary within about one second, and the unified log names no other cause. A second run
and the same-team run showed no wait.

Update 2026-10-30: the quickstart run from the published packages waited about seven minutes at
`[0/6]` while three keychain dialogs waited for the user. The guest account's keychain item dated
from an earlier run, and its access list admitted only an earlier build. Each new program asked once,
and "Always Allow" ended the prompts. The four-minute wait above most likely had the same cause. An
item that `parbake --keychain` creates with an ad-hoc build is open to every program and never asks.

## negative

- Two different teams, such as a Developer ID against Apple's own identity, were not tested,
  because only one identity was available.
- No network plugin of our own was tested. `container network create --plugin <name>` exists in
  the fork and in stock 1.5.0, and plugin names drive the mach service names (`Plugin.swift:59-71`).
  Shipping a renamed build of `container-network-vmnet` with the plugin's signature is therefore a
  plausible way past status 1001. It is not verified.

## leads

- Run the plugin against services and a network plugin of the plugin's own signature, with the guest
  on a network created by `container network create --plugin`.
- Read vmnet's rule for sharing a network across processes, to name the check behind status 1001.
