<!-- doc_type: runbook -->

# End-to-end checklist

Run this checklist before a release, and after a change to the runtime, the guest agent or `parbake`.
It builds a bundle, boots guests and checks the failure paths that `task check` does not reach.
It ends with the development services stopped and the installed services running again.

## Scripted package run

`task e2e:package` runs the published packages through install, verify, bundle and guest boot, and writes a receipt.
`task e2e:package:candidate VERSION=X.Y.Z` runs the same steps against a local candidate package before the tag.

Both are attended and stop the stock services. `PKG_E2E_ATTENDED=1` allows a run without a terminal.
Receipts land in `~/.parbake-e2e/receipts/<run-id>.json`, and the last line reads `RESULT pass|fail|refused <receipt>`.
`PKG_E2E_RESTORE_IMAGE` names a local restore image.
This checklist still covers the dev-build failure paths.

## Run header

Fill this table before step 1.

| Field | Value |
|---|---|
| Date | `<date>` |
| Host macOS version | 27.x |
| Guest macOS version | 27.x |
| Tested commit | `<commit>` |
| Signing mode | Apple Development identity; identifiers omitted |
| Bundle-roots line used | `/Volumes/<external-volume>/parbake-e2e` |

## Prerequisites

- A macOS 27 host with room for three bundles of about 30 GB each.
- The patched apple/container fork that `scripts/dev-env.sh build` clones and builds, as [CONTRIBUTING.md](../CONTRIBUTING.md) describes. A stock release does not work.
- Optional: an Apple Development identity for `parbake`. Set `PARBAKE_CODESIGN_IDENTITY` to the identity's name as [signing.md](signing.md) describes, and leave `CODESIGN_IDENTITY` unset. Without it, `task sign` signs ad hoc.
- The run stops the installed container services and restarts them in step 20. Running containers stop.
- The login keychain is unlocked.
- The bundles live under the home directory. A bundle on an external volume needs the plugin's access to removable volumes, and macOS asks for it once for each new plugin build. Grant it after step 3 and before the first boot, in System Settings › Privacy & Security › Files & Folders. Until then the start waits without a message.

## Placeholders

Replace each placeholder once, in every command below.

| Placeholder | Meaning |
|---|---|
| `<bundle>` | Absolute path of a fresh bundle, for example `/Users/<user>/parbake-e2e/e2e.bundle` |
| `<key.pub>` | Path of a public key file for the guest account |
| `<noagent-bundle>` | Absolute path of a layer bundle built from `<bundle>` whose script removes the agent's LaunchDaemon |
| `<remove-agent.sh>` | Path of a script that runs `rm /Library/LaunchDaemons/container-runtime-macos.agent.plist` |
| `<stale-bundle>` | Absolute path of a provisioned bundle whose installed agent comes from an older or differently versioned build |
| `<volume-bundle>` | Absolute path of a bundle on a volume under `/Volumes`, outside your home directory |

In the commands, `parbake` stands for `"$(task bin-path)/parbake"` and `dev` stands for `scripts/dev-env.sh`.
Run every command from the Parbake checkout.

## Steps

| # | Command | Expect | Result |
|---|---|---|---|
| 1 | `task clean check` | Exit 0: lint, build, sign and tests pass | Pass: exit 0 |
| 2 | `parbake create --keychain --username runner --authorized-key <key.pub> --bundle <bundle>` | Exit 0; `<bundle>` holds `Provisioned` and `Agent` | Pass: exit 0; `Provisioned` reads `runner`, `Agent` reads `1 0.1.0` |
| 3 | `dev up -y` | The installed services stop; `dev status` reports development services | Pass, with the stamped plugin signed ad hoc |
| 4 | `dev run <bundle> --name mac1`<br>`dev container ls` | `mac1` is running and `ls` shows an address for it | Pass: `mac1` has an assigned address. The plugin already had access to removable volumes, so the bundle on the external volume opened without a prompt |
| 5 | `dev container exec mac1 sw_vers`<br>`dev container exec -t mac1 /bin/zsh -c tty` | `sw_vers` prints the guest version; `tty` prints a `/dev/ttys` path | Pass: the guest version and an allocated TTY are reported |
| 6 | `time dev container stop mac1` | Exit 0 within the timeout | Pass: exit 0 within the timeout |
| 7 | `parbake layer --base <bundle> --bundle <noagent-bundle> --script <remove-agent.sh>`<br>`dev run <noagent-bundle> --name late --label runtime-macos.readiness-timeout=20` | The start fails after about 20 s with the agent timeout text; no guest keeps running | Pass: the start fails after about 20 s with the agent timeout text, and no guest remains running |
| 8 | `dev container start mac1`<br>`dev run <bundle> --name mac2`<br>`dev run <bundle> --name mac3` | The third start fails with the text that two guests run; stop one, or reboot the host if fewer run | Pass: the third start names the two-guest limit, and the failed container is already removed |
| 9 | `dev container rm mac3`<br>`for i in 1 2 3 4 5; do dev container stop mac2 && dev container start mac2; done`<br>`dev container stop mac2 && dev container start mac2` | All five cycles and the sixth start succeed | Pass: five cycles and the sixth start |
| 10 | `dev container stop mac2 && dev container rm mac2`<br>`dev container ls`<br>`dev container stop mac1 && dev container start mac1`<br>`dev container ls` | `mac1` shows an address before and after the restart; the address may differ | Pass: `mac1` has an address before and after the restart. The address changes, because the network service allocates a new address and MAC on every start |
| 11 | `dev container stop mac1 && dev container rm mac1`<br>`dev run <bundle> --name mac1`<br>`pkill -9 -x container-runtime-macos`<br>`dev container rm mac1`<br>`find ~/.container-macos-dev -name Overlay.asif` | `find` prints nothing after the stop and again after the kill | Pass: `find` prints nothing both times |
| 12 | `/usr/bin/log show --info --last 10m --predicate 'subsystem == "container-runtime-macos"'` | Entries for bootstrap, start, stop and the errors of steps 7 and 8 | Pass with `--info`: bootstrap, start, stop and both errors. Call the binary as `/usr/bin/log`, because zsh has a `log` builtin |
| 13 | `parbake --version`<br>`"$(task bin-path)/container-runtime-macos" --version`<br>`cat <bundle>/Agent` | Local builds print `0.0.0-dev` from both and `Agent` reads `1 0.0.0-dev`; a release build prints the tag version and `Agent` reads `1 <tag version>` | Pass: `0.1.0`, `0.1.0`, `1 0.1.0` |
| 14 | `dev run <bundle> --name bad -v /tmp:/tmp`<br>`dev run <bundle> --name bad -p 8080:80` | Each run is refused before the VM starts and names its flag | Pass: `-v/--mount` and `-p/--publish` refused in bootstrap |
| 15 | `dev container run -d --runtime container-runtime-macos --label 'runtime-macos.bundle=~/VM.bundle' alpine`<br>`dev run <volume-bundle> --name vol`<br>`echo "$(dirname <volume-bundle>)" >> "$HOME/Library/Application Support/container-runtime-macos/bundle-roots"`<br>`dev run <volume-bundle> --name vol` | The first run is refused as not absolute. The second is refused as outside the roots, naming the roots file. The third boots. | Pass: not absolute; outside the roots, naming the file; the third run boots the bundle on the volume and answers `exec` |
| 16 | `dev run <bundle> --name mac1`<br>`dev container kill -s HUP mac1`<br>`dev container exec -u root mac1 launchctl bootout system/com.openssh.sshd`<br>`dev container exec -u root mac1 launchctl bootout system/container-runtime-macos.agent`<br>`dev container stop mac1 &`<br>`dev container kill -s KILL mac1` | `HUP` is refused and names the allowed signals. `KILL` force-stops the guest at once. | Pass: `HUP` refused with TERM, INT, QUIT or KILL; `KILL` stops the guest and the pending stop at once |
| 17 | `dev run <bundle> --name mac1`<br>`time dev container exec mac1 sudo shutdown -r now`<br>`time dev container exec mac1 sudo shutdown -h now` | The reboot restarts the guest inside the VM, so the first `exec` ends within about 70 s with the "guest kept running" message. `shutdown -h now` ends with the "guest stopped" message. | Pass: the reboot ends `exec` within about 70 s with the "guest kept running" message, and `shutdown -h now` with the "guest stopped" message |
| 18 | `dev run <stale-bundle> --name old`<br>`/usr/bin/log show --info --last 5m --predicate 'subsystem == "container-runtime-macos"' \| grep 'parbake agent install'` | `old` starts; the log shows the stale-agent warning once, because the running agent reports a release that differs from the plugin's | Pass: `old` starts, and the log shows the stale-agent warning once |
| 19 | `dev container exec mac1 yes \| head -c1`<br>`dev container exec mac1 sw_vers` | The second `exec` prints the guest version | Pass: the second `exec` prints the guest version |
| 20 | `dev container ls -a`<br>`dev container rm -f <each name still listed>`<br>`dev down` | The development services stop; `dev status` reports the installed services | Pass: the installed services run |

## Recorded runs

Keep host-specific run records outside the repository. Do not publish exact
build identifiers, signing identifiers, volume names, commit hashes or measured
timings in this checklist. Summaries in the repository omit those identifiers.
