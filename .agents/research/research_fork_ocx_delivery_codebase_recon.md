# Research: Relocating the fork's container build

## Metadata

**Date:** 2026-10-26
**Domain:** packaging
**Triggered by:** `.agents/discussions/fork-container-ocx-delivery.md`, codebase recon lane
**Expires:** 2027-04-26, or on the next fork rebase

Paths prefixed `C:` are relative to the fork checkout `.build/dev-env/container` (fork `0f824548`).

## Direct Answer

The fork's build can be relocated. Its install root comes from the executable's own path, and the
app root is set by a flag. Stock and fork cannot run at the same time, because the apiserver's
launchd label and Mach service are fixed strings.

## Findings

### Roots

- The install root is resolved in this order: env `CONTAINER_INSTALL_ROOT`, then the grandparent
  of the executable path (`C:Sources/ContainerPlugin/InstallRoot.swift:22-33`). Symlinks in that
  path are not resolved.
- `system start --install-root` overrides it. The start command passes the value to the apiserver
  and to every plugin as `CONTAINER_INSTALL_ROOT` (`C:Sources/ContainerCommands/System/SystemStart.swift:45,111`,
  `C:Sources/ContainerPlugin/PluginLoader.swift:275`).
- The app root is resolved in this order: `--app-root`, then `CONTAINER_APP_ROOT`, then
  `~/Library/Application Support/com.apple.container` (`C:Sources/ContainerPlugin/ApplicationRoot.swift:22-34`).
- The apiserver plist is generated at start into `<appRoot>/apiserver/apiserver.plist` and holds
  absolute binary paths. The apiserver path has its symlinks resolved first (`SystemStart.swift:93-96,105,123`).
- Two config layers: `<installRoot>/etc/container/config.toml` (default) and
  `<appRoot>/config/config.toml` (user) (`C:Sources/ContainerPersistence/ConfigurationLoader.swift:55-70`).
- The Makefile defaults to `DEST_DIR ?= /usr/local/` (`C:Makefile:31`). No `/usr/local` literal was
  found in Sources. The grep was not conclusive.

### launchd

- The apiserver label and its Mach service are both `com.apple.container.apiserver`, a fixed
  string. Clients hard-code the same name (`SystemStart.swift:116,121`,
  `C:Sources/Services/ContainerAPIService/Client/ClientHealthCheck.swift:24`).
- Plugin labels follow the pattern `com.apple.container.<plugin>[.<id>]`
  (`C:Sources/ContainerPlugin/Plugin.swift:22,45-67`).
- `system stop` and `system status` take `--prefix`, default `com.apple.container.`. `start` has
  no prefix option.
- Consequence: one apiserver per user session. `scripts/dev-env.sh` stops the installed services
  before `up` and restarts them in `down`. It detects the running build from `program =` in
  `launchctl print gui/<uid>/com.apple.container.apiserver`.

### Plugins

- The apiserver scans `<installRoot>/libexec/container-plugins` (user, only if it exists) and
  `<installRoot>/libexec/container/plugins` (built-in) (`C:Sources/APIServer/APIServer+Start.swift:185-203`).
- No env var and no app-root plugin directory exist.
- Symlinks are followed for the directory and for each entry (`PluginLoader.swift:62-67,114,126-136,213-226`).
  So a plugin can live outside the install root through a symlink. Not tested.

### Build output and first start

- `make container` installs into the checkout itself:
  - `bin/{container,container-apiserver,update-container.sh,uninstall-container.sh}`
  - seven built-in plugins under `libexec/container/plugins/`, each with `bin/` and `config.toml`
- `pkgbuild` uses `--install-location /usr/local` (`C:Makefile:189`).
- `system start` pulls the init image if it is missing. It downloads the kernel unless
  `--disable-kernel-install` is set. Both go under the app root.
- Parbake's plugin config sets `requiresKernel`, `requiresInitImage` and `requiresImageSnapshot`
  to false.

### Signing

- Fork entitlements: only `com.apple.security.virtualization`, and only on `container-runtime-linux`
  and `container-network-vmnet` (`C:signing/*.entitlements`). No restricted entitlement and no
  provisioning profile are used.
- Signing defaults to ad hoc (`--sign -`, `C:Makefile:40`). Signing with entitlements happens only
  in the `installer-pkg` target.
- Parbake also needs only `com.apple.security.virtualization`. `docs/signing.md` explains that an
  ad-hoc identity changes on every build, which affects the keychain ACL.

## negative

- No label or Mach-name override exists, so true side-by-side running is not possible.
- No plugin-dir env var exists.
- No OCX package for container or Parbake exists yet.

## leads

- Test a symlinked `libexec/container-plugins` entry that points at a read-only store path.
- Test whether ad-hoc binaries started by launchd from a store path pass amfid. See the comment at
  `SystemStart.swift:89-92`.
- Patching the label constants (about six sites) would make true side-by-side use possible.
