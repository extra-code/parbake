<!-- doc_type: tutorial -->
<!-- doc_tier: first-steps -->

# Quickstart: run a macOS guest from the Parbake packages

By the end of this page, a macOS guest runs as a container on your Mac, started from two published OCX packages. You build nothing from source.

Two packages make the combination. [`container`](https://ocx.sh/catalog/extra-code/container) is a temporary patched build of Apple `container`, from the extra-code/container fork. [`parbake`](https://ocx.sh/catalog/extra-code/parbake) is the runtime plugin and the `parbake` command. You join them with three symlinks under `~/.parbake`. You keep your stock `container` install, but only one set of `container` services runs at a time.

## Requirements

- A Mac with Apple silicon and macOS 27.
- [OCX](https://ocx.sh), the package manager that installs both packages.
- An SSH key at `~/.ssh/id_ed25519.pub`, which the guest account accepts. Create one with `ssh-keygen -t ed25519`.
- About 60 GB of free disk space: 30 GB for the bundle and 30 GB for the restore image cache.
- Optional: a stock Apple `container` install at `/usr/local/bin/container`. The steps stop it and restore it.

Set both packages once. These variables last only for the current terminal, so run every step in it.

```bash
CONTAINER_PKG=ghcr.io/extra-code/container:1.6.1_01
PARBAKE_PKG=ghcr.io/extra-code/parbake:0.1.0
```

Use the `ghcr.io` names to verify and install. The catalog lists the packages as `ocx.sh/extra-code/…`, but OCX 0.6.5 cannot check a signature through an `ocx.sh` name, and the trust policies on this page match the `ghcr.io` names. An install through an `ocx.sh` name skips the signature check and prints `no trust policy covers`.

This page walks Parbake 0.1.0, which pairs with container 1.6.1_01. The [changelog](../CHANGELOG.md) lists every release and its pairing.

## Verify the packages

Check where each package came from before you run it. This step comes first because the services run with your user rights.

1. Verify the container package against the workflow that built it:

   ```bash
   ocx package verify -p darwin/arm64 \
     --certificate-identity "https://github.com/extra-code/container/.github/workflows/ocx-package.yml@refs/tags/ocx-1.6.1_01" \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com "$CONTAINER_PKG"
   echo "exit status: $?"
   ```

   The check passes when the exit status is 0.

   ```text
   exit status: 0
   ```

2. Verify the Parbake package the same way:

   ```bash
   ocx package verify -p darwin/arm64 \
     --certificate-identity "https://github.com/extra-code/parbake/.github/workflows/release.yml@refs/tags/v0.1.0" \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com "$PARBAKE_PKG"
   echo "exit status: $?"
   ```

   ```text
   exit status: 0
   ```

   Exit status 77 means the package has no signature. Exit status 79 means the signature does not match the identity you gave.

3. Add one trust policy per package to the OCX config file, `~/.ocx/config.toml`. With a policy, every install verifies the signature and fails closed. Each `identity_regexp` accepts every release tag of its workflow. Write both once:

   ```bash
   mkdir -p ~/.ocx
   cat >> ~/.ocx/config.toml <<'EOF'
   [[trust.policy]]
   scope = "ghcr.io/extra-code/container"
   signers = [
     { kind = "keyless",
       identity_regexp = "^https://github.com/extra-code/container/.github/workflows/ocx-package.yml@refs/tags/ocx-[0-9]+\\.[0-9]+\\.[0-9]+_[0-9]{2}$",
       oidc_issuer = "https://token.actions.githubusercontent.com" },
   ]

   [[trust.policy]]
   scope = "ghcr.io/extra-code/parbake"
   signers = [
     { kind = "keyless",
       identity_regexp = "^https://github.com/extra-code/parbake/.github/workflows/release.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$",
       oidc_issuer = "https://token.actions.githubusercontent.com" },
   ]
   EOF
   ```

   The commands print nothing. OCX reads `$OCX_HOME/config.toml`, and `~/.ocx` is the default OCX home. `--config` or `OCX_CONFIG` names an extra file that OCX layers on top.

A signature attests which workflow built a package. It does not attest that anyone reviewed the content. The binaries are signed ad hoc and are not notarised.

## Install the packages

The `container` package is a temporary patched build of Apple `container`. It goes away once Apple ships the patches.

1. Install both packages and keep a link to each:

   ```bash
   ocx package install --link ~/.parbake/container "$CONTAINER_PKG"
   ocx package install --link ~/.parbake/plugin "$PARBAKE_PKG"
   ```

   Do not pass `--select` to either install: neither package joins your shell `PATH`. OCX verifies each signature, downloads the package and prints the installed reference and its link. The first install can take a while. The output of the first line is shown below.

   ```text
   Package                                Version                                Path
   ghcr.io/extra-code/container:1.6.1_01  ghcr.io/extra-code/container:1.6.1_01  /Users/<you>/.parbake/container
   ```

   A line `no trust policy covers …` means the install skipped the signature check. Check the reference and the policies, then install again.

   An authorisation error, or a link path that already exists as a directory and exits 65, is covered in [Parbake package troubleshooting](package-troubleshooting.md#error-ocx-package-install-fails).

2. Build the root of symlinks. The services read the fork's files and the plugin from this one directory:

   ```bash
   mkdir -p ~/.parbake/root/libexec/container-plugins
   ln -s ~/.parbake/container/content/bin ~/.parbake/root/bin
   ln -s ~/.parbake/container/content/libexec/container ~/.parbake/root/libexec/container
   ln -s ~/.parbake/plugin/content ~/.parbake/root/libexec/container-plugins/container-runtime-macos
   ```

   The commands print nothing. You create the symlinks once. An upgrade moves only an OCX link.

3. Check that the plugin is reachable through the root:

   ```bash
   ls ~/.parbake/root/libexec/container-plugins/container-runtime-macos/config.toml
   ```

   ```text
   /Users/<you>/.parbake/root/libexec/container-plugins/container-runtime-macos/config.toml
   ```

   If `ls` reports no such file, a link points at nothing. See [Parbake package troubleshooting](package-troubleshooting.md#error-run-reports-no-macos-runtime).

## Use one entry point

`~/.parbake/root/bin/container` is the only way to run the fork's `container`. The CLI takes its install root from the path it was started from. A `container` reached through `ocx package exec` or the store path sees the store as its root and misses the plugin. `parbake` needs no root, so it runs as `ocx package exec "$PARBAKE_PKG" -- parbake …`.

## Switch to Parbake

Stopping the stock services also stops every container that runs under them. List them first.

1. If a stock install exists, show its running and stopped containers:

   ```bash
   /usr/local/bin/container ls -a
   ```

   Finish or stop any job you need to keep. The output below is illustrative.

   ```text
   ID  IMAGE  OS  ARCH  STATE  ADDR
   ```

2. Stop the stock services:

   ```bash
   /usr/local/bin/container system stop
   ```

   The command returns to the prompt when the services have stopped.

3. Start the services of the fork through the root:

   ```bash
   ~/.parbake/root/bin/container system start --install-root ~/.parbake/root --app-root ~/.parbake/app --disable-kernel-install
   ```

   `--disable-kernel-install` skips the Linux kernel, which macOS guests do not use. The start still needs the network for the init image. The services keep their data in `~/.parbake/app`. The first start can be slow. The output below is illustrative.

   ```text
   Starting container services...
   Verifying apiserver is running...
   ```

4. Check which services run:

   ```bash
   launchctl print gui/$(id -u)/com.apple.container.apiserver | grep program
   ```

   The `program` line shows the store path of the container package, resolved. The digest path is a placeholder here.

   ```text
   program = /Users/<you>/.ocx/packages/<digest>/content/bin/container-apiserver
   ```

   If the line shows another path, see [Parbake package troubleshooting](package-troubleshooting.md).

## Create a bundle

A bundle is the macOS VM image that every guest boots from. Create one with `parbake create`. It downloads macOS, installs it and creates the account. The bundle takes about 30 GB.

```bash
ocx package exec "$PARBAKE_PKG" -- parbake create --username ci --authorized-key ~/.ssh/id_ed25519.pub
```

The command prompts for the account password. The download and install take a while. The command ends with the bundle path, `~/VM.bundle` unless you set `PARBAKE_HOME`, and a line that names the label to run a container from it. The output below is illustrative.

```text
==> Created <bundle-path>
Run a container from it with --label runtime-macos.bundle=<bundle-path>
```

The plugin boots only bundles under your home directory. For a bundle elsewhere, add its directory to the [bundle-roots file](../README.md#bundle-roots) before `container run`.

## Run a guest

1. Start a guest from the bundle:

   ```bash
   ~/.parbake/root/bin/container run -d --name mac1 \
     --runtime container-runtime-macos \
     --label runtime-macos.bundle=$HOME/VM.bundle \
     --cpus 4 --memory 8G \
     alpine
   ```

   The image reference is required by the CLI and otherwise unused. The command prints the container name.

   ```text
   mac1
   ```

2. List the running container:

   ```bash
   ~/.parbake/root/bin/container ls
   ```

   The `OS` column shows the placeholder image, not the guest. The output below is illustrative.

   ```text
   ID    IMAGE                            OS     ARCH   STATE    IP          CPUS  MEMORY   STARTED
   mac1  docker.io/library/alpine:latest  linux  arm64  running  <address>   4     8192 MB  <time>
   ```

3. Run a command in the guest:

   ```bash
   ~/.parbake/root/bin/container exec mac1 sw_vers
   ```

   The output names the macOS version of the guest. The values below are placeholders.

   ```text
   ProductName:            macOS
   ProductVersion:         <version>
   BuildVersion:           <build>
   ```

4. Stop the guest and remove the container:

   ```bash
   ~/.parbake/root/bin/container stop mac1
   ~/.parbake/root/bin/container rm mac1
   ```

   Each command prints the container name. The container and its overlay are gone. The bundle stays.

   ```text
   mac1
   mac1
   ```

## Switch back

Stop the services through the root, then start the stock install.

```bash
~/.parbake/root/bin/container system stop
/usr/local/bin/container system start
```

Run the `launchctl print` line again. The `program` line shows the stock apiserver.

```text
program = /usr/local/bin/container-apiserver
```

The stock `container ls` works again.

## Next steps

- [Upgrade or uninstall the packages](package.md).
- [Fix a package problem](package-troubleshooting.md), such as a `program` line that shows the wrong path.
- [README](../README.md) lists the run options, the bundle roots, the limitations and the exit codes.
- [Security](../SECURITY.md) covers the trust model, and [Signing](signing.md) explains the ad-hoc signature.
