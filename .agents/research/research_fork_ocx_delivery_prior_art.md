# Research: Shipping a forked container through a package manager

## Metadata

**Date:** 2026-10-26
**Domain:** packaging
**Triggered by:** `.agents/discussions/fork-container-ocx-delivery.md`, prior-art lane
**Expires:** 2027-04-26

Some sources were read through a summarising fetch, so their quotes are paraphrases.

## Direct Answer

OCX can hold the fork's build as an immutable, digest-addressed bundle. The bundle carries entry
points, env vars, dependencies and keyless signatures. OCX documents no post-install hook. A
source-building package-manager recipe for apple/container shows that a non-pkg install works:
- a prefix install root;
- ad-hoc signing;
- wrapper scripts;
- a service the package manager runs.

## Findings

### OCX 0.6.5

Sources: `ocx package {create,push,sign,attest,select,install} --help` and the ocx.sh docs.

- **Store:** `~/.ocx/packages/<registry>/sha256/<shard>/` holds `content/`, `metadata.json` and
  `refs/`. A digest path never changes its contents.
- **Version links:** `candidates/<tag>` is pinned at install. `current` moves only through
  `ocx package select`. `install --link PATH` adds a pin that protects the package from `ocx clean`.
- **metadata.json:**
  - `type: bundle`
  - `env` with `${installPath}`
  - `dependencies`, pinnable by digest
  - `binaries`
  - No hooks or post-install field is documented. That is not confirmed as absent.
- **Signing:** `ocx package sign` and `ocx package attest` sign keylessly, with an OIDC token from
  CI. `install` and `pull` verify, failing closed, only when a `[[trust.policy]]` covers the
  package.
- **Not covered by the docs:** macOS quarantine, codesign and launchd plists.
- **Local check:** a package installed here ([`uv`](https://ocx.sh/catalog/astral-sh/uv)) carries
  no `com.apple.quarantine` attribute.
- **Index:** the [ocx.sh package index](https://ocx.sh/catalog/) lists published packages.

### apple/container distribution

- **Official:** a signed .pkg into `/usr/local`, with `uninstall-container.sh` and
  `update-container.sh`.
- **A source-building package-manager recipe:**
  - installs plugins under `libexec/container-plugins`;
  - re-signs everything ad hoc with identifiers `com.apple.container.*`;
  - uses `bin` wrapper scripts that set `CONTAINER_INSTALL_ROOT`;
  - runs `container system start --disable-kernel-install` as its service;
  - stops the services after every install. How it avoids clashing with the .pkg was not verified.
- **Upstream docs:** `system start` has `--app-root`, `--install-root` and `--log-root`. They say
  nothing about side-by-side installs.

### Gatekeeper fact pattern

Community sources, not Apple documentation.

- Browsers and Mail set `com.apple.quarantine`. curl and tools that bypass the quarantine API do
  not.
- A binary without that attribute is not checked by Gatekeeper on first launch. arm64 code needs
  at least an ad-hoc signature.
- A forum thread reports a notarised CLI that was still blocked while the attribute was present.

### Keyless signing versus notarisation

- Keyless signing ties a manifest digest to an OIDC identity, such as a GitHub Actions workflow.
  It gives provenance and tamper evidence.
- macOS never consults it. It is no malware scan and earns no Gatekeeper or Background Task
  Management trust. It does not replace a Developer ID or restricted entitlements. That last point
  is an inference.

## negative

- OCX documents nothing about hooks, quarantine, codesign or plists.

## leads

- Run `ocx package test` on a package, then check it with `xattr -l` and `codesign -dv`.
- Read the OCX "Verify installs" and "Pin a signer identity" guides.
