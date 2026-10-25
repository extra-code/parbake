<!-- doc_type: readme -->

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/parbake-logo-dark.svg">
    <img src="docs/assets/parbake-logo-light.svg" alt="Parbake" width="520">
  </picture>
</p>

# Parbake

Parbake runs ephemeral macOS guests on Apple silicon through Virtualization.framework, as
`container-runtime-macos`, a runtime plugin for [apple/container](https://github.com/apple/container).

- Each container boots its own instance of an installed macOS VM bundle. The source bundle stays unchanged.
  The instance reads the bundle's ASIF disk image read-only and writes into its own DiskImageKit overlay,
  which refuses to stack on any other base. A bundle with a raw disk image is refused.
- The init process of the container is the guest: `container start` boots it, and the container exits when the guest shuts down.
- `container stop` shuts the guest down through the guest agent, over SSH with its `GuestKey` when the
  bundle has no agent. It waits at least 60 seconds for the shutdown, whatever `--time` says. A guest without
  either gets a power-button request. Either way the guest
  is stopped forcibly once the wait passes. `container kill` shuts the guest down the same way, and
  `container kill -s KILL` stops it at once.
- The guest joins the container's network, by default container's `default` network. The network
  allocates its address and MAC address, and `container ls` shows the address. That network runs no
  DHCP server. The runtime starts its own interface on the network and answers the guest's DHCP
  requests with that address, the gateway and the DNS servers. The guest image needs no change. A
  container without a network uses Virtualization.framework NAT.

How the plugin, the guest agent and Apple `container` work together: [docs/architecture.md](docs/architecture.md).

## What is supported

- The guest agent is experimental. Its protocol and the bundle `Agent` file may change before a stable release.
- The supported host is macOS 27 on Apple silicon, see [ADR 0007](docs/adr/adr_0007_hosts_run_macos_27_and_disks_are_asif.md).
- The tested guest runs macOS 27.
- Parbake needs apple/container `804209b1` with three runtime-plugin commits, tag `parbake-804209b1`
  of the [extra-code/container](https://github.com/extra-code/container) fork.
  A stock `container` release is unsupported.

## Requirements

- Mac with Apple silicon, macOS 27 or later, Xcode 27 (macOS 27 SDK)
- [OCX](https://ocx.sh) for `task` and the lint tools. Run `ocx pull` once in the checkout, and the OCX shell hook puts `task` on `PATH`
- For `--username` provisioning and the guest agent: a macOS 27 or later guest
- A patched apple/container build. A stock `container` release is unsupported:
  the plugin config needs `[runtimeConfig]` support, which the fork's commits add.
  `Package.swift` pins the fork by revision, and SwiftPM fetches it. `scripts/dev-env.sh build`
  clones the same revision into `.build/dev-env/container` and builds the CLI and services there.
  [CONTRIBUTING.md](CONTRIBUTING.md) has the full set-up.
- A macOS VM bundle with an ASIF `Disk.img`, `AuxiliaryStorage`, `HardwareModel` and `MachineIdentifier`, as `parbake create` builds it
- Do not boot a bundle read-write while containers run from it: their overlays build on its disk as it is.

## Quick start

```bash
task sign                          # build and sign the plugin, parbake and the guest agent
"$(task bin-path)/parbake" create --username ci --authorized-key ~/.ssh/id_ed25519.pub
                                   # download macOS, install it into ~/VM.bundle, create the account
scripts/dev-env.sh up              # build container and the plugin, switch to the development services
scripts/dev-env.sh run ~/VM.bundle # boot a macOS container from the bundle
scripts/dev-env.sh down            # stop the development services, restart the installed ones
```

- `parbake create` downloads the latest restore image this host supports into
  `~/Library/Caches/parbake`, resumes interrupted downloads, and reuses completed ones, then
  installs macOS and provisions the account. `--restore-image` takes another image instead: a path,
  or an `http(s)` URL such as a mirror, downloaded into the cache. After a successful download the
  cache keeps only the image just used, and `--keep-cache` keeps the others.
- `parbake create --replace` rebuilds an existing bundle. It builds next to it, as
  `<bundle>.parbake-new`, and takes its place only once provisioning succeeded, so a failed build
  leaves the existing bundle as it was. The volume needs room for a second bundle meanwhile.
  Containers made from the old bundle no longer stack on the new disk image: remove them, or let
  `--label runtime-macos.on-incompatible-overlay=discard` start them over. `parbake create --help`
  lists the options.
- `parbake create --config parbake.toml` reads the bundle from a file, so an image pipeline is
  declarative. Paths in the file are relative to it, an unknown key is an error, and options on the
  command line take precedence. The scripts run as root through the guest agent after
  provisioning, and a failing script fails the build.

  ```toml
  bundle = "/Volumes/external-disk/parbake/VM.bundle"
  disk-size = 100

  [account]
  username = "ci"
  authorized-keys = ["~/.ssh/id_ed25519.pub"]
  keychain = true

  [guest]
  tidy = true
  sudo = ["/usr/sbin/softwareupdate"]   # allowed without a password, besides /sbin/shutdown
  scripts = ["setup.sh"]
  ```

- Bundles and the restore image cache take about 30 GB each. To keep them off the internal disk, set
  `PARBAKE_HOME` to a directory on an external SSD, for example
  `PARBAKE_HOME=/Volumes/external-disk/parbake parbake create …`. The bundle then defaults to
  `$PARBAKE_HOME/VM.bundle` and the cache to `$PARBAKE_HOME/cache`. Containers keep their overlays in
  container's data directory and link to the bundle's disk image. A bundle may live on another
  volume.
  Keep the disk attached while a guest runs from it, and prefer an SSD to a USB stick. Format the
  disk as APFS: on a Journaled HFS+ SSD over USB, one guest's disk writes stalled in the kernel
  during its first boot. Every access to its disk image hung, and the guest process could not be ended.
- `dev-env.sh` builds apple/container in `.build/dev-env/container` and keeps its data in
  `~/.container-macos-dev`. The installed container keeps its binaries, data and containers.
  Both register the same launchd service, so `up` stops the installed services and `down`
  starts them again.
- With `--username`, the first boot after the installation creates that account with automatic
  login and Remote Login, without the Setup Assistant. One SSH session then adds the public key from
  `--authorized-key` and the bundle's own `GuestKey` and allows the account to run `/sbin/shutdown`
  without a password (`/etc/sudoers.d/parbake`). The session also turns Spotlight indexing off, empties the caches
  with `--tidy` and installs the guest agent as a LaunchDaemon (`--no-agent` skips it). Once the
  agent answers over vsock, provisioning writes its version to `Agent` in the bundle and shuts the
  guest down through it. The password is prompted for. Without
  `--username`, the guest opens in a window for the Setup Assistant.
- On a CI host, add `--keychain`: the password comes from the login keychain (generic password,
  service `container-runtime-macos.guest`, account = username). When the keychain has none,
  provisioning generates a random one and stores it there, so no person types or sees it. Read it
  back with `security find-generic-password -s container-runtime-macos.guest -a ci -w`. An
  ad-hoc `parbake` reaches the keychain through `/usr/bin/security` and creates the entry with `-A`, so a
  rebuilt or updated `parbake` never waits on a keychain dialog. A `parbake` signed with a team
  identity stores the entry in process with a creator-only access list. See
  [SECURITY.md](SECURITY.md#keychain-access-follows-the-signing-identity). `create --username` without
  `--keychain` reads a piped stdin password before the download. The login keychain must be unlocked, which a LaunchAgent in a
  logged-in session has and a LaunchDaemon has not.
- `create` chains these steps in order:
  1. `install` puts macOS into the bundle.
  2. With `--username`, `provision` creates the account on the first boot. Provisioning also installs the guest
     agent, unless you pass `--no-agent`. Without `--username`, `setup` opens the guest for the Setup Assistant,
     unless you pass `--no-setup`.
  3. With `--username`, the scripts from `--script` or `[guest] scripts` run as root through the guest agent.

  `provision` runs only on the first boot after `install`, and writes `Provisioned` into the bundle.
- These commands stay standalone, and `create` never runs them:
  - `parbake agent install` installs or updates the guest agent in a provisioned bundle. It writes to the
    bundle's disk image, so remove containers made from the bundle first.
  - `parbake layer` builds a layer bundle, described below.
  - `parbake agent-probe` checks a development build of the agent against a provisioned bundle.
  - `parbake state-probe` measures a start from a saved guest state against a cold boot.
  - `parbake install`, `provision` and `setup` also run on their own, for example to redo one step by hand.
- `parbake layer --base ~/VM.bundle --bundle ~/Xcode.bundle --script install.sh` creates a layer
  bundle for software many containers need, such as Xcode. It links the base's disk image and boots
  with a layer of its own on top. It runs the script as root through the guest agent and shuts the
  guest down. A container from the layer bundle reads base and layer and writes only to its
  overlay. The base stays unchanged, and a failed script leaves no layer bundle behind. A layer
  bundle cannot be the base of another layer. Rebuilding the base makes its layers unusable, as it
  does for overlays.

## Configuration file {#configuration-file}

`parbake create --config parbake.toml` reads these keys. Every key is optional except `username` in `[account]`.
An unknown key is an error. A relative path is relative to the file, and `~` is your home directory.
An option on the command line takes precedence over the same key in the file.

| Key | Type | Command-line option |
|---|---|---|
| `bundle` | string, path | `--bundle` |
| `restore-image` | string, path or `http(s)` URL | `--restore-image` |
| `disk-size` | integer, GiB | `--disk-size` |
| `cpus` | integer | `--cpus` |
| `memory` | integer, GiB | `--memory` |
| `[account] username` | string | `--username` |
| `[account] full-name` | string | `--full-name` |
| `[account] authorized-keys` | array of strings, public key files | `--authorized-key`, repeatable |
| `[account] keychain` | boolean | `--keychain` |
| `[account] keychain-service` | string | `--keychain-service` |
| `[guest] tidy` | boolean | `--tidy` |
| `[guest] agent` | boolean | `--agent` and `--no-agent` |
| `[guest] sudo` | array of strings, commands | `--sudo`, repeatable |
| `[guest] scripts` | array of strings, script files | `--script`, repeatable |

## Standalone commands {#standalone-commands}

`parbake <command> --help` lists every option. Each line below names the flags of one command.

- `parbake install --bundle --restore-image [--disk-size --cpus --memory]` creates a bundle and installs macOS.
- `parbake provision --bundle --username [--full-name --authorized-key --sudo --keychain --keychain-service --tidy --agent --no-agent --cpus --memory --timeout]`
  creates the account on the first boot.
- `parbake setup --bundle [--cpus --memory]` boots the bundle in a window for the Setup Assistant.
- `parbake agent install --bundle [--agent --keychain --keychain-service --timeout]` installs or updates the guest agent.
- `parbake agent-probe --bundle [--agent --timeout]` checks a development build of the agent.
- `parbake state-probe --bundle --work-dir [--memory --timeout]` measures a saved-state start against a cold boot.
  One more flag boots the bundle itself and writes to its disk, see `--help`.
- `parbake layer --bundle --script [--base --replace --cpus --memory --timeout]` builds a layer bundle.

`parbake layer` takes these options:

| Option | Meaning |
|---|---|
| `--base` | Base bundle the layer stacks on. Default `$PARBAKE_HOME/VM.bundle`, else `~/VM.bundle` |
| `--bundle` | Layer bundle to create |
| `--script` | Shell script to run as root in the guest |
| `--replace` | Replace an existing layer bundle once the new one is complete |
| `--cpus` | CPUs while the script runs. Default 4 |
| `--memory` | Memory in GiB while the script runs. Default 8 |
| `--timeout` | Seconds to wait for the guest agent after the boot. Default 300 |

## Bundle roots {#bundle-roots}

The plugin boots only bundles under your home directory. To allow another directory, such as an external SSD,
list its absolute path in `~/Library/Application Support/container-runtime-macos/bundle-roots`.
Write one path per line. Blank lines and lines starting with `#` are skipped.
The file must belong to you and must not be writable by group or others.
A bundle is refused when it or its layout files belong to another user or are writable by others.

## Build and install

```bash
task sign                             # build and sign with the virtualization entitlement
task test
task install INSTALL_ROOT=/usr/local  # installs to <root>/libexec/container-plugins
container system stop                 # restart the services so they load the plugin
container system start
```

- `INSTALL_ROOT` is the root of the container installation that loads the plugin. It defaults to `/usr/local`.
- `parbake` and `parbake-agent` are installed next to the plugin binary.
- `task` builds the debug configuration by default. `CONFIGURATION=release` builds and installs a release build.
- `/usr/local/libexec` is usually owned by root. Create the plugin directory once and hand it to your user,
  so that `task install` runs without `sudo`:

  ```bash
  sudo mkdir -p /usr/local/libexec/container-plugins
  sudo chown -R "$USER" /usr/local/libexec/container-plugins
  ```

  Running `sudo task install` instead leaves root-owned files that a later `task install` cannot replace.
- `container system stop` stops every running container. Stop or finish your jobs first.

`task sign` signs ad hoc. To sign `parbake` with an Apple Development identity, set `PARBAKE_CODESIGN_IDENTITY`.
The plugin stays ad hoc. [docs/signing.md](docs/signing.md) explains why and what a Developer ID adds.

## Run

```bash
container run -d --name mac1 \
  --runtime container-runtime-macos \
  --label runtime-macos.bundle=$HOME/VM.bundle \
  --cpus 4 --memory 8G \
  alpine
container exec mac1 sw_vers           # needs the guest agent
container stop mac1
container rm mac1
```

- `--name` sets the container ID that `exec`, `stop` and `rm` take. Without it, `container run` picks an ID, and `container ls` shows it.
- `container rm` removes the container and its overlay. The bundle stays.
- After `scripts/dev-env.sh up`, the `container` on your `PATH` is the installed one. Use
  `scripts/dev-env.sh container exec mac1 sw_vers` or `.build/dev-env/container/bin/container` for the development services.
  `scripts/dev-env.sh run ~/VM.bundle` starts a container with the same options as above, and `scripts/dev-env.sh help` lists every command.
- `runtime-macos.bundle` names the VM bundle to boot.
- `runtime-macos.on-incompatible-overlay` decides what happens when a container's overlay no longer
  stacks on the bundle's disk image, for example after the bundle was installed again. `fail`
  (default) stops the start with an error. `discard` drops the overlay and the guest's writes and
  starts the instance over on the bundle, keeping its machine identifier.
- `runtime-macos.readiness-timeout` sets how many seconds the start waits for the guest agent after
  the boot (default 180). It applies to a bundle whose `Agent` file says an agent is installed. The
  guest is stopped and the start fails when the agent does not answer in time.
- The image reference is required by the CLI and otherwise unused.
- The guest gets at least 4 GiB of memory.

## Limitations {#limitations}

- The plugin refuses mounts (`-v`, `--mount`), published ports (`-p`, `--publish`) and `--publish-socket`.
  The start fails and names each refused input.
- The guest is the init process. The run command, `--env`, `--workdir` and `--user` of `container run` do not reach it.
- `container exec` honours its own `--env`, `--user` and `--workdir`.
- At most two macOS guests run at the same time per host. Virtualization.framework refuses a third,
  and the start fails with a message that says so. Scheduling within the limit is the caller's job.
- `exec` needs the guest agent in the guest. It runs as the provisioned account in its login session,
  with its keychain and its own `TMPDIR`. `--user root` runs as root. `exec -t` runs on a terminal.
- A job writes to the account's home and `TMPDIR`. The system volume is read-only. Both live in the
  container's overlay and go with the container.
- When the guest stops during an `exec`, the exec fails with an error naming the guest's stop instead
  of an exit code, and the container is `stopped`. A caller tells a guest failure from a job failure
  by the container state, see [ADR 0008](docs/adr/adr_0008_what_a_ci_executor_can_rely_on.md).
- A second start of a container whose guest is still booting is refused. Stopping a container while the VM starts force-stops it. A stop during the wait for the guest agent is an ordinary stop. A stop whose forced stop fails reports an error.
- Signals that the CLI forwards to an `exec` process fail in apple/container itself
  ([apple/container#1941](https://github.com/apple/container/issues/1941)).
- `cp`, `stats`, `dial`, `export` and `clean` return "unsupported".
- Stop signals other than `KILL` request a guest shutdown. Other signals are refused.
- The guest has no attached terminal. `run -it` shows no guest output.

## Exit codes {#exit-codes}

`parbake` exits with these codes. On failure it prints `Error: <message>` to stderr. `parbake --help` prints to stdout and exits 0.

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | A runtime error, a failed precondition (already provisioned, no account, no guest agent, too little free space), or any error not listed below. No usage banner |
| 3 | A script failed. The message names the script and its exit status |
| 64 | Usage: a bad argument or config. stderr contains `Usage:` |
| 66 | A VM bundle or one of its layout files is missing, or a `--restore-image` path does not exist. Checked before the lock and the download |
| 69 | Two macOS guests already run, or the keychain is locked or refused access |
| 75 | A lock is held, or the guest got no DHCP lease, no SSH answer or no agent answer in time |

## Logs and troubleshooting {#logs-and-troubleshooting}

- In the guest, the agent logs to `/var/log/parbake-agent.log`.
- The plugin helper logs one file per container, `container-runtime-macos-<container uuid>.log`,
  in the directory `CONTAINER_LOG_ROOT` names for the container services.
  Without that variable, the helper writes only to the unified log.
- Read the unified log on the host:

  ```bash
  log show --info --predicate 'subsystem == "container-runtime-macos"' --last 10m
  ```

  Without `--info`, `log show` prints only the errors.

Each failure below has a known cause and one remedy.

| Failure | Cause | Remedy |
|---|---|---|
| A path is in use by another process | A lock on the bundle's auxiliary storage is held | Wait for the other process, or remove the lock file if that process is gone |
| No DHCP lease within N seconds | The guest did not finish booting, or the network gave no lease | Check the lease file the message names and that the guest booted |
| `user@address` did not answer over SSH | Remote Login is off in the guest | Enable Remote Login in the guest |
| The guest agent did not answer within N seconds | The agent is missing, broken or slow | Run `parbake agent-probe`, or raise `runtime-macos.readiness-timeout` |
| The keychain item is not available | The login keychain is locked | Unlock the login keychain and log in to a GUI session |
| The keychain refused access | Access to the item is denied | Allow it in Keychain Access, or remove the item and retry |
| No VM bundle, or a layout file is missing | The path is wrong or the bundle is incomplete | Create the bundle with `parbake create` |
| The host already runs two macOS guests | The Virtualization.framework limit | Stop one guest. If none runs, a slot leaked: reboot the host |

## Remove everything {#remove-everything}

Stop the services first with `container system stop`. Then remove these items.

1. Containers and their overlays: `container rm --force <name>` for each one.
2. The development data: `rm -rf ~/.container-macos-dev`.
3. The bundle, and any leftovers of a failed `--replace` or build:
   `rm -rf ~/VM.bundle ~/VM.bundle.parbake-new ~/VM.bundle.parbake-old ~/VM.bundle.parbake-lock`.
   Use `$PARBAKE_HOME/VM.bundle` or your own bundle path if you moved it.
4. The restore image cache: `rm -rf ~/Library/Caches/parbake`, or `$PARBAKE_HOME/cache`.
5. The keychain item for each account:
   `security delete-generic-password -s container-runtime-macos.guest -a <user>`.
6. The bundle roots file: `rm -f "$HOME/Library/Application Support/container-runtime-macos/bundle-roots"`.
7. The plugin: `task uninstall INSTALL_ROOT=/usr/local`.

## Development services

`scripts/dev-env.sh help` lists every command, flag and variable of the development script.

Before a release, run the [end-to-end checklist](docs/end_to_end_checklist.md).

## Security

[SECURITY.md](SECURITY.md) covers reporting a vulnerability and the trust model.
[CHANGELOG.md](CHANGELOG.md) lists the changes of each release.

## License

Parbake is licensed under the [Apache License 2.0](LICENSE).
