# Draft: Runtime plugins that run no OCI image

Unposted draft for a Discussion at apple/container.

## Problem

A runtime plugin whose workload is not an OCI image still has to name and pull one. `container run`
resolves the image argument, fetches it, reads its registry login, and stores it in the container
configuration. `container ls` then shows the platform of that image, not of the workload.

For a plugin that boots a VM bundle or another non-image payload, the image is a placeholder. It costs
a registry round trip, may trigger a keychain prompt, and puts a wrong `OS` and `ARCH` in `ls` and
`inspect`.

## Proposal

A plugin declares in its `config.toml`:

```toml
[runtimeConfig]
requiresImage = false
platform = "darwin/arm64"
```

When the user passes `--runtime <plugin>` explicitly, the named plugin is found and decodes, and
`requiresImage` is `false`, the CLI behaves as follows:

- It skips the image lookup and the pull. The image argument stays required and is otherwise ignored.
- It stores the placeholder image reference `<none>` and records the plugin's platform.
- A conflicting `--platform`, `--os` or `--arch` is an error naming the runtime and the flag.
- Without a command, the container gets an empty process. The plugin owns what runs.
- `container commit` refuses such a container before any image lookup.
- A plugin with `requiresImage = false` but no `platform` fails with an error naming the config file.
- A plugin with `requiresImage = false` must also set `requiresKernel = false` and `requiresImageSnapshot = false`; otherwise its config is invalid.

A missing or undecodable plugin never means "skip".

## Compatibility

- No schema change. Existing container configurations decode unchanged.
- Without `--runtime`, the default runtime selection from the image is unchanged, including the
  behaviour discussed in PR #2422 and issue #1376.
- Plugins that omit the two keys behave as before.

## Running example

The fork extra-code/container carries this as a commit on branch `parbake`: `<commit>`.
A runtime plugin built on it boots a macOS guest from a VM bundle. The end-to-end run
starts the guest with `container run … none` and passes with these result lines:

```text
RESULT pass <receipt>   (run-id <run-id>, candidate build)
RESULT pass <receipt>   (run-id <run-id>, published build)
```

`container ls` shows `<none>`, `darwin` and `arm64` for the guest. No image is pulled.

## Follow-up idea

The image argument could become optional when `--runtime` names an image-less plugin. This draft keeps
it required to leave the CLI grammar untouched.

## Question

Is a pull request for this welcome? If so, I would follow CONTRIBUTING and split it into the plugin
config keys, the CLI skip, and the `commit` refusal.
