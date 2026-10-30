<!-- doc_type: troubleshooting -->

# Troubleshoot the Parbake packages

This page lists the problems that appear when you run the `container` and `parbake` OCX packages next to a stock `container` install.

The commands below use two variables. They last only for the current terminal. Set them to the references you run.

```bash
CONTAINER_PKG=ghcr.io/extra-code/container:1.6.1_01
PARBAKE_PKG=ghcr.io/extra-code/parbake:0.1.0
```

Most problems show in one line. Run it after every start, stop or upgrade.

```bash
launchctl print gui/$(id -u)/com.apple.container.apiserver | grep program
```

The fork's services show a `program` path in the OCX store, under `~/.ocx/packages`. The stock services show `/usr/local/bin/container-apiserver`. A path that differs from the one you expect points to one of the entries below.

## Error: `ocx package install` fails

This issue occurs when you lack access to a private package on `ghcr.io`, or when the `--link` path exists as a directory or a file.

Check: the install stops with an authorisation or "denied" message, or `--link` exits with status 65 and `ls -ld ~/.parbake/container` does not start with `l`.

Fix: for an authorisation error, ask the package owner for access, then log in with an account that has it:

```bash
ocx login ghcr.io
```

For status 65, the same fix applies to `~/.parbake/plugin`. Skip the stop when the services are not running. Otherwise stop them, move the path away and install again:

```bash
~/.parbake/root/bin/container system stop
mv ~/.parbake/container ~/.parbake/container.old
ocx package install --link ~/.parbake/container "$CONTAINER_PKG"
```

For `~/.parbake/plugin`, move that path and install with `"$PARBAKE_PKG"`.

## Warning: `no trust policy covers` during an install

This issue occurs when the install reference does not match a trust policy, for example an `ocx.sh/extra-code/…` name. The policies match the `ghcr.io/extra-code/…` names. OCX installs the package without checking its signature.

Check: the install prints `no trust policy covers '<reference>'` and `without signature verification`.

Fix: set the variables to the `ghcr.io` names above and install again. An `ocx.sh` name with a matching policy fails instead, because OCX 0.6.5 cannot check a signature through the index name.

## Error: the first `run` waits at `[0/6]`

This issue occurs when the guest account's keychain item already exists and only an earlier build may read it. macOS then asks before each new program reads it. An item that `parbake create --keychain` creates opens to every program, so a new item never asks.

Check: `container run` shows `[0/6]` for minutes, and a keychain dialog asks to allow access to `container-runtime-macos.guest`.

Fix: answer each dialog with "Always Allow" and your login password. Or delete the item in Keychain Access. The next `parbake` run with `--keychain` creates it again, open to every program.

## Error: the stock services answer instead of the fork's

This issue occurs when the stock apiserver still runs while you start the fork's services, or when a stock `container` CLI talks to the fork's services. Both use the same Mach service name. A second `system start` reports success against the daemon that already runs (apple/container#1757).

Check: the `program` line shows `/usr/local/bin/container-apiserver`, or the stock `container ls` shows the fork's containers.

Fix: stop the stock services, then start the fork's again. Use only `~/.parbake/root/bin/container` while the fork's services run.

```bash
/usr/local/bin/container system stop
~/.parbake/root/bin/container system start --install-root ~/.parbake/root --app-root ~/.parbake/app --disable-kernel-install
```

## Error: `run` reports no macOS runtime

This issue occurs when a symlink in the root points at nothing. The plugin loader skips a missing directory without a message.

Check: `container run --runtime container-runtime-macos` fails because the runtime is unknown, and this `ls` fails:

```bash
ls ~/.parbake/root/libexec/container-plugins/container-runtime-macos/config.toml
```

Fix: remove the broken symlink, create it again as in [Install the packages](quickstart.md#install-the-packages), then restart the services.

## Error: services stay old or fail after an upgrade or `ocx clean`

This issue occurs when a link moves while the services run. It also occurs when `ocx clean` or a removed link takes the files under their store paths. The old services keep running until they restart.

Check: the `program` line shows the digest path of the old version, or helper and plugin starts fail and the `program` path no longer exists.

Fix: stop the services, link both packages again, then start the services.

```bash
~/.parbake/root/bin/container system stop
ocx package install --link ~/.parbake/container "$CONTAINER_PKG"
ocx package install --link ~/.parbake/plugin "$PARBAKE_PKG"
~/.parbake/root/bin/container system start --install-root ~/.parbake/root --app-root ~/.parbake/app --disable-kernel-install
```
