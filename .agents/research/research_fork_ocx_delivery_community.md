# Research: apple/container community on side-by-side and relocatable installs

## Metadata

**Date:** 2026-10-26
**Domain:** packaging
**Triggered by:** `.agents/discussions/fork-container-ocx-delivery.md`, community lane
**Expires:** 2027-01-26. The threads are open and move fast.

Sources: `gh` searches of apple/container issues and pull requests on 2026-10-26. The maintainers
quoted are jglogan and timsneath.

## Direct Answer

Upstream makes no provision for two installs running at once. A second `system start` with
another app root silently reports success against the daemon that is already running. The install
root should stay at a stable path. jglogan notes that a path changing on each release confuses
TCC local network privacy. Services must restart on every upgrade, because the APIs are not
backward compatible.

## Findings

### Collisions

- **#1757** (open): the apiserver label and its Mach service are fixed. While daemon A runs,
  `system start --app-root B` pings A and reports success. The ping returns A's `appRoot`, but
  `start` discards it. Fix PR #1795 was closed unmerged.
- **#1671** (closed): a leftover launchd service from a package-manager install, next to a .pkg
  install, made the apiserver exit with status 78. Uninstalling and reinstalling fixed it.
- **#1672** (open): an unvalidated `system stop --prefix` value goes straight into
  `launchctl bootout` and can log the user out. PR #1717 (open) adds validation.

### Install root

- **#622** (open): jglogan says users "really don't need to know" about the install root. A rename
  of `--app-root` to `--data-root` was agreed. PR #1705 updates the docs.
- **PR #1415** (open): jglogan argues against resolving symlinks for the install root.
  - Package-manager paths that change per release confuse TCC local network privacy.
  - Symlinks are resolved only for the executable path in launchd plists, for Gatekeeper.
  - Third-party plugins belong in `${INSTALL_ROOT}/libexec/container-plugins/<id>`.
- **#1670** (closed): `install-root` in the user `config.toml` was used as a workaround. Whether
  that is an official key is unverified.

### Plugin directory

- **#1617** (open) asks for a stable user plugin directory, because plugins in a package-manager
  install root are lost on upgrade. PR #1618 (open) adds `$XDG_DATA_HOME/container/plugins`.
  Neither has a maintainer reply.

### Signing

- **#1682** (open): the release .pkg fails `pkgutil --check-signature`, and the binaries inside are
  signed ad hoc.
- Package-manager recipes for apple/container also sign ad hoc, with `com.apple.container.*`
  identifiers.

### Upgrades

- **#551:** jglogan says services must restart on every upgrade. Package-manager recipes stop them
  after each install with `ensure-container-stopped.sh -a`.
- **#1942:** jglogan declined a `container upgrade` command, because it would have to know how
  the tool was installed.
- Package-manager recipes put env shims in `bin/` that set `CONTAINER_INSTALL_ROOT`. Their service
  runs `system start --disable-kernel-install`.

## negative

- No thread covers two installs coexisting by design.

## leads

- Read #1450 and PR #1451 for the intended bundle layout.
