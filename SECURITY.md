<!-- doc_type: reference -->

# Security

This page covers how to report a vulnerability, which versions get fixes, and the trust model of Parbake.

## Report a vulnerability

Report privately through GitHub private vulnerability reporting.
Open the repository's Security tab and choose "Report a vulnerability".
Do not open a public issue for a vulnerability.

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x | Yes |

## Trust model

Parbake is built for a dedicated CI user account on a Mac you control.
It does not defend that account against code that runs inside it.

| Topic | Behaviour |
|---|---|
| Guest password with ad-hoc signing | Every process of the CI user can read the guest password from the login keychain. |
| Guest password with a stable identity | Only the `parbake` that created the item can read it. Set `PARBAKE_CODESIGN_IDENTITY` as described in [docs/signing.md](docs/signing.md#sign-with-the-identity). |
| Signing default | Builds are signed ad hoc. A stable identity is opt-in. |
| SSH host keys | Host-key checking is off for guests, in `Sources/RuntimeMacOS/GuestShell.swift`. |
| Restore images | Parbake downloads them without a checksum check. |
| Bundle roots | The plugin boots only bundles under the home directory and the paths in the bundle-roots file. |
| `--sudo` | The operator who builds a bundle owns its guest. A sudo rule lets a job, as the CI account, run that command as root. |
| `--script` | The script runs as root in the guest. |
| Release packages | A release publishes two OCX packages, `ghcr.io/extra-code/container` and `ghcr.io/extra-code/parbake`, signed keylessly. See [Release packages](#release-packages). |

### Keychain access follows the signing identity

The keychain item for the guest password is created for any application when the build is signed ad hoc.
A build signed with a stable identity creates the item for itself only.
[ADR 0010](docs/adr/adr_0010_keychain_access_follows_the_signing_identity.md) records the measurement behind this design.

### SSH host-key checking

Parbake connects to a guest with host-key checking off and no known-hosts file.
The exposure is limited because the guest runs on the host's own vmnet network.
Only the host and its other guests can reach it.

### Bundle roots

An XPC bundle label must resolve to a path under an allowed root.
The home directory is always allowed.
[Bundle roots](README.md#bundle-roots) in the README explains how to add another directory.

### Sudo rules

`--sudo` and `[guest] sudo` accept absolute command paths only, with no arguments and no wildcards.
[ADR 0011](docs/adr/adr_0011_guest_sudo_rules_and_provisioning_config.md) records the rule and its reasons.

### Release packages

The extra-code/container fork publishes `ghcr.io/extra-code/container:<upstream>_<build>`, a temporary patched build of Apple `container`. A Parbake tag run publishes `ghcr.io/extra-code/parbake:X.Y.Z`, which holds the plugin and the `parbake` command.
In both repositories the build job holds `contents: read`. Only the `publish` job holds `packages: write` and `id-token: write`.

The `publish` job runs no repository code. The build job verifies the package root and records the SHA-256 of the archive and of its metadata. The publish job compares both before it pushes.
[ADR 0015](docs/adr/adr_0015_ship_the_fork_and_parbake_as_two_ocx_packages.md) records the design.

The `announce` job and the `announce` workflow open a pull request against the ocx.sh index. Neither holds repository permissions. Their token is a classic personal access token with only the `public_repo` scope, because a fine-grained token cannot open a pull request in a public repository its owner does not own. The token lives only in the `release` environment. That environment requires the owner's approval and admits release tags and `main`, the branch the claim and announce workflows run from.

To pin the signer, verify with the identity of one release and the issuer `https://token.actions.githubusercontent.com`.
A trust policy in the OCX `config.toml` (`$OCX_HOME/config.toml`, which defaults to `~/.ocx/config.toml`) can accept every release. Each package has its own `identity_regexp`:

```toml
# ghcr.io/extra-code/container
identity_regexp = "^https://github.com/extra-code/container/.github/workflows/ocx-package.yml@refs/tags/ocx-[0-9]+\\.[0-9]+\\.[0-9]+_[0-9]{2}$"
# ghcr.io/extra-code/parbake
identity_regexp = "^https://github.com/extra-code/parbake/.github/workflows/release.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$"
```

The tag rulesets give `refs/tags/ocx-` and `refs/tags/v` their meaning, because only maintainers create those tags.
[docs/quickstart.md](docs/quickstart.md#verify-the-packages) shows the commands.

- A signature attests which workflow built a package. It does not attest that anyone reviewed the content.
- The binaries are signed ad hoc and are not notarised. Gatekeeper and TCC treat them as unidentified.
- Verification is opt-in. Without a trust policy or an explicit `ocx package verify`, an install skips it.
- The fork's apiserver runs as the user, with the virtualization entitlement.
- The fork's Makefile runs in the fork's build job with its rights. That is a first-party trust assumption.
- Builds are not reproducible.
