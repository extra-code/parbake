<!-- doc_type: changelog -->

# Changelog

## v0.1.0

### Added

- The `container-runtime-macos` plugin runs an ephemeral macOS guest as a container on Apple silicon.
- The `parbake` command provisions, layers and installs the agent in macOS VM bundles.
- The guest agent reports readiness to the plugin and runs scripts as root.
- Parbake exit codes: 64 usage, 66 missing VM bundle or restore image path, 69 VM limit or keychain locked or refused, 75 lock held or timeout, 3 guest script failed, 1 anything else.
- [SECURITY.md](SECURITY.md) covers private reporting and the trust model.
- [docs/end_to_end_checklist.md](docs/end_to_end_checklist.md) lists the host run that gates a release.

### Changed

- `container run` with `-v`, `--mount`, `-p`, `--publish` or `--publish-socket` now fails. These options were ignored before.
- A bundle outside the home directory needs a line in the [bundle-roots file](README.md#bundle-roots) before its next `container run`.
- `parbake` exits with the new codes instead of 64 for runtime failures.
- `--sudo` and `[guest] sudo` accept absolute command paths only.
- The agent version line is `<protocol> <release>`. Local and untagged builds report `0.0.0-dev` from both CLIs and `1 0.0.0-dev` from the agent; a release build reports the tag version. Bundles provisioned earlier keep working and log a warning until `parbake agent install` runs.
- A second start of a container whose guest is booting is refused. Stopping a container while the VM starts force-stops it. A stop during the wait for the guest agent is an ordinary stop. A stop whose forced stop fails reports an error.
- Keychain access follows the signing identity. A `parbake` signed with a team identity creates the guest password item for itself only. An ad-hoc build keeps the item readable by every application of the user.
