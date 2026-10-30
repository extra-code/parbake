---
title: Parbake
description: Run macOS guests as containers with Apple container on Apple silicon.
keywords: macos,virtualization,container,apple-silicon,ci
---

# Parbake

Parbake is a runtime plugin for Apple `container`. It runs macOS guests as containers on a Mac with Apple silicon, from a macOS VM bundle that the `parbake` command creates.

This package holds the plugin and the `parbake` command. It runs with [`extra-code/container`](https://ocx.sh/catalog/extra-code/container), a temporary patched build of Apple `container`.

## Install

Install both packages, each behind a link under `~/.parbake`:

```bash
ocx package install --link ~/.parbake/container ghcr.io/extra-code/container:1.6.1_01
ocx package install --link ~/.parbake/plugin ghcr.io/extra-code/parbake:0.1.0
```

The install lines use the registry names, because the signature trust policies match them.

The [quickstart](https://github.com/extra-code/parbake/blob/main/docs/quickstart.md) verifies the signatures, joins the two packages, starts the services and runs a first guest.

## Update

Stop the services, then re-run the install line of the package that changed, with its new tag:

```bash
~/.parbake/root/bin/container system stop
ocx package install --link ~/.parbake/plugin ghcr.io/extra-code/parbake:<new-version>
```

The [changelog](https://github.com/extra-code/parbake/blob/main/CHANGELOG.md) names the container tag each Parbake release pairs with. [Upgrade and uninstall](https://github.com/extra-code/parbake/blob/main/docs/package.md) covers the details.

## Links

- Source: [github.com/extra-code/parbake](https://github.com/extra-code/parbake)
- Security: [SECURITY.md](https://github.com/extra-code/parbake/blob/main/SECURITY.md)
