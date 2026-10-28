# Research: Hosting an OCX package on the project's ghcr.io

## Metadata

**Date:** 2026-10-26
**Domain:** packaging
**Triggered by:** `.agents/discussions/fork-container-ocx-delivery.md`, registry thread. Per the
user, the OCX maintainer welcomes hosting in the project's own GitHub context.
**Expires:** 2027-04-26

Sources: the local `ocx` 0.6.5 `--help` output, the docs source at github.com/ocx-sh/ocx under
`website/src/content/docs/`, ocx.sh/docs and docs.github.com. ocx.sh pages were read through a
summarising fetch.

## Direct Answer

OCX pushes to and installs from any OCI registry, and its own docs use ghcr.io as the example. A
release workflow can push to `ghcr.io/extra-code/parbake` with the workflow token, sign keylessly
with `id-token: write`, and link the package to the repository through
`org.opencontainers.image.source`. Users install by the full reference. A short name needs a
reviewed entry in the [ocx.sh package index](https://ocx.sh/catalog/), which the `ocx-sh/index`
repository backs. Announcing to the index needs a personal access token.

## Findings

### Publish

```
ocx package create build -p darwin/arm64 -m metadata.json -o parbake-0.1.0.tar.xz
ocx package push -p darwin/arm64 -m metadata.json --ci-annotations=github --sign \
  -i ghcr.io/extra-code/parbake:0.1.0 parbake-0.1.0.tar.xz
```

- `metadata.json` declares `env`, `entrypoints` and `dependencies`. Entry points land on PATH when
  the package is selected.
- `--cascade` also moves the rolling tags (`0.1`, `0`, `latest`), and `--tags-file` records what
  was pushed.
- `--sign` signs each platform manifest inline. `ocx package sign` and `ocx package attest`
  (cyclonedx, spdx, slsaprovenance1) can also run afterwards.
- By default OCX also writes `__ocx.keep.sha256-<hex>` tags, which show up in the GHCR package.
  `--no-keep-tag` turns them off.

### Auth

- **Credential order:** OCX first reads `OCX_AUTH_ghcr_io_{TYPE,USER,TOKEN}`, then the registry
  credential file that OCI clients share.
- **Login:** `ocx login ghcr.io -u <user> --password-stdin` needs `--allow-insecure-store` on a CI
  runner without a keychain. Otherwise it exits 78.
- **Signing:** keyless signing needs `id-token: write`. OCX detects the token from the environment,
  or reads it from `OCX_IDENTITY_TOKEN`.
- **Anonymous pull:** the auth type `anonymous` exists. A public GHCR package can be pulled without
  authentication. No OCX doc states this as the default.
- **Not found:** an `ocx login` example that uses `GITHUB_TOKEN`.

### GHCR

- `--ci-annotations=github` sets `org.opencontainers.image.source`, `.revision`, `.created` and
  `.version`.
  - The source annotation links the package to the repository, and the package inherits the
    repository's access permissions.
  - It does not inherit visibility.
- The first publish creates a private package. An owner flips it to public by hand, and that cannot
  be undone.
- No source on retention was found.

### Index

The [ocx.sh package index](https://ocx.sh/catalog/) has one page per package at
`https://ocx.sh/catalog/<namespace>/<name>`, for example https://ocx.sh/catalog/astral-sh/uv.
`https://index.ocx.sh/` redirects there.

- `ocx package claim --repository oci://ghcr.io/extra-code/parbake extra-code/parbake` opens a PR
  on `ocx-sh/index`. A human reviews it. Afterwards `ocx package install extra-code/parbake`
  resolves the short name.
- `ocx package announce --tags-file tags.txt extra-code/parbake` records new tags. The docs say
  `GITHUB_TOKEN` cannot replace the `INDEX_PAT` that announcing needs.

### Trust policy

The policy lives in the user's `config.toml`, not in `ocx.toml`.

```toml
[[trust.policy]]
scope = "ghcr.io/extra-code/*"
signers = [
  { kind = "keyless",
    identity_regexp = "^https://github.com/extra-code/parbake/.github/workflows/release.yml@refs/tags/v",
    oidc_issuer = "https://token.actions.githubusercontent.com" },
]
```

- `install` and `pull` verify only when a policy covers the package, and then they fail closed.
  Without a policy a package installs unverified, with an INFO line.
- Manual check: `ocx package verify -p darwin/arm64 --certificate-identity … --certificate-oidc-issuer https://token.actions.githubusercontent.com ghcr.io/extra-code/parbake:0.1.0`.

### Examples

- `ghcr.io/michael-herwig/ocx-e2e-hello` is announced in the index (index PRs #86 to #88). It is the
  author's own fixture.
- No independent project was found.

## negative

- No `ocx.toml` binding example with a ghcr reference was found.
- No GHCR retention rules were found.

## leads

- Read the release workflows of `ocx-sh/ocx` and `ocx-sh/setup-ocx`.
- Read `reference/environment.md` for `OCX_AUTH_*`.
