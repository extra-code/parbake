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
