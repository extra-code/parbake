State: handed-off → plan · Updated: 2026-10-26
Ratified: 2026-10-26 → plan
Confidence: ratified by the user; research vintage 2026-10-26 (six lanes, fork `0f824548`)

# Discussion: Isolated delivery of the fork's container through OCX

## Intent

Make Parbake something people can try within a few steps. Today a user builds the fork of
apple/container from source, builds Parbake, installs the plugin into the fork's install root and
signs ad hoc. The idea is to ship the fork's build and Parbake as OCX packages, isolated from a
stock `container` install. OCX installs without the quarantine attribute and can sign packages
keylessly. OCX is already in use elsewhere to deliver a macOS app this way. Outcome shape: a plan
(`/hex-plan`).

## Decisions

- **Exclusive and switchable.** Stock and fork can both be installed, but only one runs. Starting
  Parbake's services stops a running stock install and records that. Stopping them restarts the
  stock install, as `scripts/dev-env.sh` does today. The fork gains no label patch, which keeps the
  upstream diff unchanged. Reason: the apiserver label and Mach name are fixed upstream (#1757), and
  a label patch would be a permanent fork change Apple does not need.
- **One package.** A single OCX package holds the fork's build in its install-root layout, with the
  plugin, `parbake` and `parbake-agent` under `libexec/container-plugins/container-runtime-macos/`.
  One digest is one tested combination. Plugin and fork are already coupled through
  `Package.resolved`. Nothing is assembled at install, and the read-only root is fine because data
  lives in the app root.

- **Everything signed ad hoc.** No certificate and no CI secret. The fork's services, the plugin
  and `parbake` share one signing domain, as package-manager recipes for apple/container do. Accepted cost: each release
  is a new code identity, so a keychain item created by a team-signed build stays out of reach, and
  ad-hoc builds create items with `-A` (ADR 0004, ADR 0010). Open decision 3 in the plan stays open
  for a later stable identity.
- **Docs, no service command.** A quickstart page lists the commands:
  1. Stop a stock install.
  2. Start the services with the package's `container`, `--app-root` and `--disable-kernel-install`.
     The install root follows from the binary's path.
  3. Always use the package's CLI.
  4. Switch back.

  The page names three traps and their check line,
  `launchctl print gui/$(id -u)/com.apple.container.apiserver | grep program`:
  - `system start` reports false success while a stock apiserver runs (#1757);
  - a stock CLI talks to the fork's apiserver through the shared Mach name;
  - after an update the old apiserver keeps running until it is restarted (#551).

  A command follows only if these traps show up in practice. The name `parbake setup` is taken.
- **Registry: `ghcr.io/extra-code/parbake`.** The package is hosted in the project's own GitHub
  context. The user reports the OCX maintainer welcomes this
  (`.agents/research/research_fork_ocx_delivery_ghcr_hosting.md`). The tag workflow pushes with
  `--ci-annotations=github --sign`. The owner flips the package to public once, by hand, and that
  is irreversible. Users install by the full reference.

- **A separate publish job.** The build job keeps `contents: read`. A second job with
  `packages: write` and `id-token: write` downloads the finished artifact, then logs in, pushes and
  signs. No build code runs with write rights.
- **Index later.** Release 0.1.0 is installed by its full reference. Listing it in the
  [ocx.sh package index](https://ocx.sh/catalog/) through `ocx package claim` and `announce` needs
  an `INDEX_PAT`, and comes after 0.1.0 is proven.

## Requirements

- **Build job.** `release.yml` builds the fork at the `Package.resolved` revision (`make container`)
  and adds Parbake's plugin, `parbake` and `parbake-agent` under
  `libexec/container-plugins/container-runtime-macos/`. It signs everything ad hoc with the
  entitlements from the fork's `signing/` and `container-runtime-macos.entitlements`. It then runs
  `ocx package create -p darwin/arm64` with a `metadata.json` and uploads the archive as a workflow
  artifact.
- **Publish job.** It pushes `ghcr.io/extra-code/parbake:<version>` with
  `--ci-annotations=github --sign --cascade`, authenticated by the workflow token.
- **Quickstart page.** The page covers:
  - install by full reference;
  - an optional trust policy and `ocx package verify`;
  - stopping a stock install, then starting the services with `--app-root` and
    `--disable-kernel-install`;
  - creating or using a bundle, and `run` and `exec`;
  - switching back;
  - the three traps and the `launchctl print` check line;
  - uninstall.

  `README.md` links the page. Every OCX package the page or the README requires links to its entry
  in the [ocx.sh package index](https://ocx.sh/catalog/), in the form
  `https://ocx.sh/catalog/<namespace>/<name>`. Until Parbake itself is listed, it is the one
  exception and is named by its ghcr.io reference.
- **Docs and decisions.** `docs/signing.md` says "Parbake ships no binaries", which must be
  revised. A new ADR records the channel, because ADR 0013 left the channel unchosen.

## Out of scope

- A label patch in the fork, or running stock and fork at the same time.
- A `parbake service` or `doctor` command.
- A Developer ID, notarisation, or a stable signing identity (open decision 3 in
  `.agents/plans/plan_macos_runtime.md`).
- Listing Parbake in the [ocx.sh package index](https://ocx.sh/catalog/) (claim or announce).
- Distributing bundle images (open decision 2), since macOS images may not be redistributed.
- Kernel provisioning for Linux containers through the fork, and Intel hosts.

## Open questions

- [NEEDS CLARIFICATION: Do the changing digest paths matter for TCC? jglogan warns that an install
  root whose path changes per release confuses Local Network privacy (PR #1415). The apiserver path
  goes symlink-resolved into the plist, so it is always a digest path.]
  Recommended: accept it and check it in the end-to-end run. The macOS path talks to the guest over
  vsock (ADR 0006), and ad-hoc signing changes the identity on every release anyway.
- [NEEDS CLARIFICATION: Should the package expose the fork's `container` as an entry point on PATH?
  If it does, it competes with a stock `/usr/local/bin/container` (trap 2).]
  Recommended: expose only `parbake`. The quickstart calls the fork's CLI by a name that cannot be
  confused with the stock one, for example an entry point `parbake-container`. The plan settles the
  name.
- [NEEDS CLARIFICATION: What is the app root's name, and can the package's `env` set
  `CONTAINER_APP_ROOT` so users omit `--app-root`?]
  Recommended: `~/.parbake`, passed as `--app-root` in the quickstart unless OCX `env` can
  reference the home directory.
- [NEEDS CLARIFICATION: Does the first `system start` show the Background Task Management notice
  on a clean user?]
  Recommended: check it in the end-to-end run and mention it in the quickstart if it appears.
- [NEEDS CLARIFICATION: Do ad-hoc signatures survive `ocx package create`, push and extraction
  intact?]
  Recommended: `codesign --verify --strict` on the installed files is part of verification.
- [NEEDS CLARIFICATION: How long does building the fork in CI take, and should it be cached?]
  Recommended: cache `.build` of the fork keyed on its revision, as CI caches SwiftPM today.

## Verification

- `task check` and the docs gate pass on the new page and the ADR.
- A dry run of `release.yml` in the fork or with `workflow_dispatch`, without pushing, produces an
  archive whose layout matches the install-root layout above. The build job holds only
  `contents: read`, the publish job only `packages: write` and `id-token: write`.
- After the 0.1.0 publish, on a macOS 27 host with a stock `container` installed:
  - `ocx package install ghcr.io/extra-code/parbake:0.1.0` installs the package.
  - `xattr -l` shows no `com.apple.quarantine`.
  - `codesign --verify --strict` passes on every binary.
  - `ocx package verify` with the release workflow identity passes.
- Following the quickstart word for word:
  - stock stops, and the fork starts with the plist program inside the OCX store;
  - a guest from a bundle on a test volume runs, and `exec sw_vers` answers;
  - `stop` and `rm` succeed;
  - switching back makes `launchctl print` show the stock program again, and `container ls` works
    against stock.

## Research

- `.agents/research/research_fork_ocx_delivery_codebase_recon.md`: the install root comes from the
  executable path or `CONTAINER_INSTALL_ROOT`, the app root from a flag. launchd names are fixed.
  Plugin symlinks are followed. Only the `com.apple.security.virtualization` entitlement is needed.
- `.agents/research/research_fork_ocx_delivery_prior_art.md`: covers the OCX package model, which
  documents no post-install hook, and keyless signing. A source-building package-manager recipe
  for apple/container is a precedent: wrapper scripts set `CONTAINER_INSTALL_ROOT`, everything is
  signed ad hoc, and the package manager runs the service.
- `.agents/research/research_fork_ocx_delivery_community.md`: covers #1757 (false success on a
  second start), the install-root stability warning in PR #1415, the user plugin directory request
  in #1617, and the restart on every upgrade (#551).
- `.agents/research/research_fork_ocx_delivery_history_and_vendors.md`: the one-apiserver
  constraint is recorded only in the `scripts/dev-env.sh` header. The signing domain must be
  shared, and `parbake setup` is already taken. Other macOS virtualization tools ship either a
  notarised pkg or app, or a source-building recipe signed ad hoc.
- `.agents/research/research_fork_ocx_delivery_ghcr_hosting.md`: covers the push, sign and install
  commands for ghcr.io, auth through `OCX_AUTH_ghcr_io_*` or the shared OCI registry credentials, the repository
  link through `--ci-annotations=github`, the manual public flip, the index claim (needs a PAT) and
  the trust-policy snippet.

## Related

- `scripts/dev-env.sh`, `Taskfile.yml` (`install`), `.github/workflows/release.yml`, `docs/signing.md`
- `.agents/plans/plan_macos_runtime.md`, open decisions 2 and 3
- Fork `extra-code/container`, tag `parbake-804209b1`
