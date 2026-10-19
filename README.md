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
  With an ASIF disk image (the default on a macOS 27 host), the instance reads the bundle's disk read-only
  and writes into its own DiskImageKit overlay, which refuses to stack on any other base. With a raw disk
  image, the instance is an APFS clone.
- The init process of the container is the guest: `container start` boots it, and the container exits when the guest shuts down.
- `container stop` shuts a provisioned guest down over SSH with its `GuestKey` and waits at least 60 seconds
  for it, whatever `--time` says; a guest without that key gets a power-button request. Either way the guest
  is stopped forcibly once the wait passes. `container kill` shuts the guest down the same way, and
  `container kill -s KILL` stops it at once.
- The guest joins the container's network, by default container's `default` network: the network
  allocates its address and MAC address, and `container ls` shows the address. That network runs no
  DHCP server, so the runtime starts its own interface on the network and answers the guest's DHCP
  requests with that address, the gateway and the DNS servers. The guest image needs no change. A
  container without a network, or a host earlier than macOS 26, uses Virtualization.framework NAT.

How the plugin, the guest agent and Apple `container` work together: [docs/architecture.md](docs/architecture.md).

## Requirements

- Mac with Apple silicon, macOS 15 or later, Xcode 27 (macOS 27 SDK)
- [OCX](https://ocx.sh) for `task` and the lint tools; run `ocx pull` once in the checkout, and the OCX shell hook puts `task` on `PATH`
- For `--username` provisioning: a macOS 27 or later host and guest
- An apple/container build whose plugin config supports `[runtimeConfig]`: the
  [extra-code/container](https://github.com/extra-code/container) fork at the revision `Package.swift` pins.
  SwiftPM fetches it, and `dev-env.sh` builds it
- An installed macOS VM bundle with `Disk.img`, `AuxiliaryStorage`, `HardwareModel` and `MachineIdentifier`, such as the bundle Apple's "Running macOS in a virtual machine on Apple silicon" sample creates
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
  installs macOS and provisions the account. `parbake create --help` lists the options.
- Bundles and the restore image cache take about 30 GB each. To keep them off the internal disk, set
  `PARBAKE_HOME` to a directory on an external SSD, for example
  `PARBAKE_HOME=/Volumes/external-disk/parbake parbake create …`: the bundle then defaults to
  `$PARBAKE_HOME/VM.bundle` and the cache to `$PARBAKE_HOME/cache`. Containers keep their overlays in
  container's data directory and link to the bundle's disk image, so a bundle with an ASIF disk image
  may live on another volume. A raw disk image must be on the same APFS volume as the containers.
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
- `create` runs the other `parbake` commands in order: `ipsw-url`, `install`, `provision` and `setup`,
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
