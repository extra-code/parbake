<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/parbake-logo-dark.svg">
    <img src="docs/assets/parbake-logo-light.svg" alt="Parbake" width="520">
  </picture>
</p>

# Parbake

Parbake runs ephemeral macOS guests on Apple silicon through Virtualization.framework, as
`container-runtime-macos`, a runtime plugin for [apple/container](https://github.com/apple/container).

- Each container boots its own instance of an installed macOS VM bundle; the source bundle stays unchanged.
  The instance reads the bundle's ASIF disk image read-only and writes into its own DiskImageKit overlay,
  which refuses to stack on any other base. A bundle with a raw disk image is refused.
- The init process of the container is the guest: `container start` boots it, and the container exits when the guest shuts down.
- `container stop` shuts the guest down through the guest agent, over SSH with its `GuestKey` when the
  bundle has no agent, and waits at least 60 seconds for it, whatever `--time` says; a guest without
  either gets a power-button request. Either way the guest
  is stopped forcibly once the wait passes. `container kill` shuts the guest down the same way, and
  `container kill -s KILL` stops it at once.
- The guest joins the container's network, by default container's `default` network: the network
  allocates its address and MAC address, and `container ls` shows the address. That network runs no
  DHCP server, so the runtime starts its own interface on the network and answers the guest's DHCP
  requests with that address, the gateway and the DNS servers. The guest image needs no change. A
  container without a network uses Virtualization.framework NAT.

How the plugin, the guest agent and Apple `container` work together: [docs/architecture.md](docs/architecture.md).

## Requirements

- Mac with Apple silicon, macOS 27 or later, Xcode 27 (macOS 27 SDK)
- [OCX](https://ocx.sh) for `task` and the lint tools; run `ocx pull` once in the checkout, and the OCX shell hook puts `task` on `PATH`
- For `--username` provisioning and the guest agent: a macOS 27 or later guest
- An apple/container build whose plugin config supports `[runtimeConfig]`: the
  [extra-code/container](https://github.com/extra-code/container) fork at the revision `Package.swift` pins.
  SwiftPM fetches it, and `dev-env.sh` builds it
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
- Bundles and the restore image cache take about 30 GB each. To keep them off the internal disk, set
  `PARBAKE_HOME` to a directory on an external SSD, for example
  `PARBAKE_HOME=/Volumes/external-disk/parbake parbake create …`: the bundle then defaults to
  `$PARBAKE_HOME/VM.bundle` and the cache to `$PARBAKE_HOME/cache`. Containers keep their overlays in
  container's data directory and link to the bundle's disk image, so a bundle may live on another
  volume.
  Keep the disk attached while a guest runs from it, and prefer an SSD to a USB stick. Format the
  disk as APFS: on a Journaled HFS+ SSD over USB, one guest's disk writes stalled in the kernel
  during its first boot; every access to its disk image hung, and the guest process could not be ended.
- `dev-env.sh` builds apple/container in `.build/dev-env/container` and keeps its data in
  `~/.container-macos-dev`. The installed container keeps its binaries, data and containers.
  Both register the same launchd service, so `up` stops the installed services and `down`
  starts them again.
- With `--username`, the first boot after the installation creates that account with automatic
  login and Remote Login, without the Setup Assistant. One SSH session then adds the public key from
  `--authorized-key` and the bundle's own `GuestKey`, allows the account to run `/sbin/shutdown`
  without a password (`/etc/sudoers.d/parbake`), turns Spotlight indexing off and empties the caches
  with `--tidy`, and installs the guest agent as a LaunchDaemon (`--no-agent` skips it). Once the
  agent answers over vsock, provisioning writes its version to `Agent` in the bundle and shuts the
  guest down through it. The password is prompted for. Without
  `--username`, the guest opens in a window for the Setup Assistant.
- On a CI host, add `--keychain`: the password comes from the login keychain (generic password,
  service `container-runtime-macos.guest`, account = username). When the keychain has none,
  provisioning generates a random one and stores it there, so no person types or sees it. Read it
  back with `security find-generic-password -s container-runtime-macos.guest -a ci -w`. Every
  access goes through `/usr/bin/security`, which creates the entry with `-A`, so a rebuilt or updated
  `parbake` never waits on a keychain dialog. The login keychain must be unlocked, which a LaunchAgent in a
  logged-in session has and a LaunchDaemon has not.
- `create` runs the other `parbake` commands in order: `install`, `provision` and `setup`,
  plus `agent install`, which installs or updates the guest agent in a provisioned bundle, and
  `agent-probe`, which checks a development build of the agent against a provisioned bundle.
  `agent install` writes to the bundle's disk image: remove containers made from the bundle first.
  `provision` runs only on the first boot after `install`, and writes `Provisioned` into the bundle.

## Build and install

```bash
task sign                             # build and sign with the virtualization entitlement
task test
task install INSTALL_ROOT=/usr/local  # installs to <root>/libexec/container-plugins
```

`INSTALL_ROOT` is the root of the container installation that loads the plugin. `parbake` and
`parbake-agent` are installed next to the plugin binary. Restart the
container system services after you install the plugin.

## Run

```bash
container run -d \
  --runtime container-runtime-macos \
  --label runtime-macos.bundle=$HOME/VM.bundle \
  --cpus 4 --memory 8G \
  alpine
```

- `runtime-macos.bundle` names the VM bundle to boot.
- `runtime-macos.on-incompatible-overlay` decides what happens when a container's overlay no longer
  stacks on the bundle's disk image, for example after the bundle was installed again: `fail`
  (default) stops the start with an error, `discard` drops the overlay and the guest's writes and
  starts the instance over on the bundle, keeping its machine identifier.
- `runtime-macos.readiness-timeout` sets how many seconds the start waits for the guest agent after
  the boot (default 180). It applies to a bundle whose `Agent` file says an agent is installed; the
  guest is stopped and the start fails when the agent does not answer in time.
- The image reference is required by the CLI and otherwise unused.
- The guest gets at least 4 GiB of memory.

## Limitations

- At most two macOS guests run at the same time per host.
- `exec` needs the guest agent in the guest. It runs as the provisioned account in its login session,
  with its keychain; `--user root` runs as root. `exec -t` is not supported yet.
- Signals that the CLI forwards to an `exec` process fail in apple/container itself
  ([apple/container#1941](https://github.com/apple/container/issues/1941)).
- `cp`, `stats`, `dial`, `export` and `clean` return "unsupported".
- Stop signals other than `KILL` request a guest shutdown.
- The guest has no attached terminal; `run -it` shows no guest output.

## License

Parbake is licensed under the [Apache License 2.0](LICENSE).
