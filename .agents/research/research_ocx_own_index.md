# Research: Running an own OCX package index and catalog under extra-code

## Metadata

**Date:** 2026-10-27
**Domain:** packaging
**Triggered by:** the user's question whether the extra-code account can run its own OCX catalog,
after `.agents/research/research_fork_ocx_delivery_ghcr_hosting.md` covered only the ocx.sh index.
**Expires:** 2027-04-27

Sources, read as source files through `gh api` unless noted:
- `ocx-sh/ocx` docs at HEAD: `explanation/indices.md`, `explanation/public-index.md`,
  `guides/serve-an-index.md`, `reference/configuration.md`
- the local `ocx` 0.6.5 `--help` output for `package claim`, `package announce`, `index`
- `ocx-sh/indexbot`: README, `docs/guide/quickstart.md`, `docs/reference/policy.md`
- `ocx-sh/catalog`: README, `docs/.../how-to/deploy-on-github-pages.mdx`,
  `docs/.../explanation/multi-source-model.md`
- `ocx-sh/index`: repository tree, `catalog.config.json`, `catalog.index-ocx-sh.json`,
  `.github/workflows/render-deploy.yml`
- the npm registry entry of `@ocx-sh/catalog`

## Direct Answer

Yes, an own index is a designed, documented use case, not a workaround.
- The OCX docs state "There is exactly one index format" with many copies: hosted, mirrored, shipped
  or local.
- The write-path bot `indexbot` says: "Nothing here is specific to it: an index is one format with
  many copies, and every per-deployment input … is committed data in the index repository".
- Its quickstart "walks an index repository from empty to serving".
- The catalog renderer `@ocx-sh/catalog` is a generic site generator "for OCI-backed package
  indices", with branding and a GitHub Pages how-to.

The cost is real, though. Every consumer must add one config entry, because only `ocx.sh` is
compiled into the client. The tooling is also pre-1.0.

## Findings

### The pieces of an own index

| Piece | What it is | Source |
|---|---|---|
| Index repository | A git repo holding `p/<ns>/<pkg>.json` roots and `p/<ns>/<pkg>/o/sha256/<hex>.json` objects, plus `.github/index-policy.json` and `.github/maintainers.yml` | indexbot quickstart |
| Policy | `{"name": "<logical name>", "name_segments": 2, "registry_hosts": ["ghcr.io"]}`; no defaults, fails closed | indexbot policy reference |
| Write path | `ocx package claim` and `ocx package announce` with `--index-repo [HOST/]NAMESPACE/PROJECT` (default `ocx-sh/index`); each opens a pull request, never a direct commit | `ocx … --help` (0.6.5) |
| PR gate and governance | `indexbot validate-pr`, `classify-pr`, `governance-check`; unprivileged and privileged workflows in separate files | indexbot README, quickstart |
| Render | `indexbot render --index-dir . --out dist` emits `config.json`, `/p/**`, `/c/index.json` | indexbot quickstart |
| Hosting | Any static host; `file://` works for air-gapped use | serve-an-index guide |
| Catalog site | `npx ocx-catalog build` from a `catalog.config.json` with `sources`, `siteUrl`, `brand`; GitHub Pages deploy documented | catalog README and how-to |
| Integrity | `indexbot reconcile` nightly, verify only, files an issue on mismatch | indexbot quickstart |

### Consumer side

- A user adds `[registries."<name>"] index = "https://…"` to the OCX config. "Field presence is the
  kind marker": with `index` set, the name resolves through the index protocol.
- Packages are then addressed by the logical name, `<name>/<ns>/<pkg>:<tag>`. The root's
  `repository` field points at the physical location, for example `oci://ghcr.io/extra-code/parbake`.
- The name "carries the registry-host grammar" but "need not equal the host serving it".
- A configured index is authoritative for its whole name. A package missing from it is a hard miss
  with no fallback to the registry, and yanked tags are refused.
- Only `ocx.sh` → `https://index.ocx.sh` ships in the compiled defaults. Any other index needs the
  config line on every machine. A managed-config tier exists to distribute config centrally; it was
  not studied here.

### Catalog aggregation

- One catalog build can list several sources, for example `index.ocx.sh` and an own index.
- Both are mirrored verbatim, and packages from both appear in one grid.

### Constraints and risks

- **Pre-1.0 tooling.** indexbot 0.x says "breaking changes ship without migration shims until 1.0 —
  pin an exact version". `@ocx-sh/catalog` is at 0.6.1.
- **Caching.** The indexbot quickstart says "Never cache `*.json`" because freshness relies on origin
  `ETag` and `If-None-Match` behind no CDN cache. Whether GitHub Pages' own caching meets that was
  not verified.
- **Headers.** The catalog's `_headers` file (CSP sandbox and nosniff over the mirrored `/p/*` tree)
  is read by Cloudflare Pages and Netlify only. On GitHub Pages it is inert.
- **Pages path.** A project Pages site serves under `/<repo>/`, so `base` must match. An
  `<org>.github.io` repository or a custom domain serves the root.
- **Credentials.** Announcing into another repository needs `OCX_ANNOUNCE_TOKEN`. A workflow's
  `GITHUB_TOKEN` is scoped to its own repository, so a cross-repository announce needs a personal
  access token or an app token. This is inferred from GitHub's token scoping, not stated in the OCX
  docs.
- **Docs version.** The OCX docs read are at HEAD, not the `v0.6.5` tag. `--index-repo` was
  confirmed in the local 0.6.5 help. The `[registries.<name>] index` key was not run locally.

## negative

- No independent third-party OCX index deployment was found. `lore.ocx.sh` is a grim index, not an
  OCX package index.
- No repository template for an index exists. `ocx-sh/index` is not marked as a template, and the
  reference deployment deploys to Cloudflare Pages, not GitHub Pages.

## leads

- Read `ocx-sh/catalog` `ops/hosting-and-headers.md` for the GitHub Pages header gap.
- Read the OCX `managed` config tier for distributing the `[registries]` entry.
- Test `[registries."<name>"] index = "file:///…"` locally against an `indexbot render` output with
  ocx 0.6.5.
