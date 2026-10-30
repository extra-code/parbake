<!-- doc_type: how-to -->
<!-- doc_tier: everyday -->

# Upgrade or uninstall the Parbake packages

This page upgrades the `container` and `parbake` OCX packages to new releases and removes them from your Mac. It assumes you installed them as in the [quickstart](quickstart.md).

Set the new references first. These variables last only for the current terminal, so run every step in it.

```bash
CONTAINER_PKG=ghcr.io/extra-code/container:<new-tag>
PARBAKE_PKG=ghcr.io/extra-code/parbake:<new-version>
```

Use the `ghcr.io` names, as in the [quickstart](quickstart.md). Only they match the trust policies.

## Order rule

Stop the services before you move or remove a link, and before you run `ocx clean`. The running services use the resolved store paths. A package without a link is removed by `ocx clean`, and its files vanish under the services.

## Upgrade

The root of symlinks stays as it is. An upgrade moves only an OCX link. Upgrade the package that changed. Set only the variable of the package that changed, and run only its install line. Check the [changelog](../CHANGELOG.md) for the container tag a Parbake release pairs with.

1. Read the release in the changelog. If a container tag moves to a new upstream version, the changelog says so. Then remove your containers before you stop the services. Run `ls ~/.parbake/app` to see what is there, and plan to run `rm -rf ~/.parbake/app` after the stop in the next step. Upstream does not keep the services' state compatible across versions.
2. Stop the services:

   ```bash
   ~/.parbake/root/bin/container system stop
   ```

3. Verify the new reference, as in [Verify the packages](quickstart.md#verify-the-packages). With a trust policy in place, the install verifies it for you.
4. Re-run `--link` for the package that changed:

   ```bash
   ocx package install --link ~/.parbake/container "$CONTAINER_PKG"
   ocx package install --link ~/.parbake/plugin "$PARBAKE_PKG"
   ```

   The link moves to the new tag. The old version stays in the store until `ocx clean`.

5. When the changelog calls for a reset, run `rm -rf ~/.parbake/app`. The stopped services hold no files in it.
6. Start the services, as in [Switch to Parbake](quickstart.md#switch-to-parbake). The `program` line shows the new digest path.

## Uninstall

1. Stop the services:

   ```bash
   ~/.parbake/root/bin/container system stop
   ```

2. Continue only after the stop printed its usual output. Remove the root and both links, then clean the store:

   ```bash
   rm -rf ~/.parbake/root
   rm ~/.parbake/container ~/.parbake/plugin
   ocx clean
   ```

   The first command removes only symlinks. The package files leave the store at `ocx clean`. Your bundles and `~/.parbake/app` stay.

3. Look at `~/.parbake/app` before you remove it:

   ```bash
   ls ~/.parbake/app
   ```

   **Warning:** `~/.parbake/app` holds the services' container state, images and logs. It never holds your bundles. Remove it only when you no longer need those containers.

   ```bash
   rm -rf ~/.parbake/app
   ```

Start the stock services again with `/usr/local/bin/container system start`.

## Next steps

- [Fix a package problem](package-troubleshooting.md).
- [Remove everything](../README.md#remove-everything) covers your bundles, the restore image cache and the keychain items.
