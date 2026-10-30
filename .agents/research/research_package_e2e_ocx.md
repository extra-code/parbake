# Research: OCX isolation, local candidate installs and trust for a package e2e test

## Metadata

- Date: 2026-10-30
- Domain: OCX CLI 0.6.5 (OCI package manager), test isolation, local registry, Sigstore trust policy
- Triggered by: Plan for a repeatable e2e test that installs two OCX packages from a clean state, once from published ghcr.io refs and once from locally built candidate archives
- Expires: 2027-04-30

## Direct Answer

- `OCX_HOME` isolates the store, index, state, trust-root cache and `$OCX_HOME/config.toml`. It does not isolate the system config, the user config, `~/.docker` credentials or the project `ocx.toml` walk.
- For a hermetic run set: `OCX_HOME=<fresh dir>`, `OCX_NO_CONFIG=1`, `OCX_NO_PROJECT=1`, and `DOCKER_CONFIG=<empty dir>` (or `OCX_AUTH_<host>_TYPE=anonymous` per registry). Pass `--config <file>` only for what the test wants (for example a trust policy).
- `OCX_NO_CONFIG=1` skips the user tier, the `$OCX_HOME` tier and the managed tier. It still loads `/etc/ocx/config.toml` (system tier, locked sections only). Nothing here read a system file, but a test cannot disable it.
- On macOS the user tier is under the platform config directory. `XDG_CONFIG_HOME` is not consulted there. Do not rely on it. Use `OCX_NO_CONFIG=1`.
- `ocx package install` takes only registry identifiers. There is no local-archive, OCI-layout or `file://` layer source. The `file://` base in docs is for the index (tag to digest metadata), not for layer bytes.
- `ocx package test -o DIR` materializes a local archive without a registry, but it does not install, does not create candidate symlinks and does not support `--link`. It is a different path from install.
- Recommended candidate mechanism: run a local plain-HTTP registry, `ocx package push` the locally built archives to it, then run the same `ocx package install --link <path> <localhost:port/repo:tag>` as in published mode. Upstream OCX does exactly this in its own test suite, with zot.
- zot is itself an OCX package: `ocx.sh/project-zot/zot:2.1.21`. It runs on macOS without Docker. The upstream suite starts it with `port: "0"` and reads the chosen port from its log.
- Plain HTTP needs `OCX_INSECURE_REGISTRIES=localhost:<port>` (byte-exact `host[:port]`) or `[registries."<host>"] insecure = true`.
- An unsigned package is reported by `ocx package verify` as `no_signatures_found`, exit 79 (not found), not 77. Exit 77 is a signer identity or issuer mismatch (and an unsigned attestation refused by policy). The task assumption of 77 for "unsigned" is wrong.
- A `[[trust.policy]]` scope is a string prefix of `registry/repository` as typed. `ghcr.io/x/y` does not cover `ocx.sh/x/y`. A scope of `ghcr.io/...` does not cover `localhost:5000/...`, so candidate installs run unverified (INFO or warning line) unless the policy is catch-all (empty or absent scope).
- `ocx package push --sign --key <ref>` signs with a local key (no OIDC, Rekor upload off by default). A policy signer `{ kind = "key", key = "<pub>" }` then lets candidate mode assert a real signature check. Not run live here.
- `ocx package install --link <path>` requires the path to be absent or an earlier `--link` of ocx, else exit 65. Cleanup: delete the link, then `ocx package uninstall --purge <ref>` inside the same `OCX_HOME`. Simplest is to delete the whole fresh `OCX_HOME`.
- `ocx --remote index list [--platforms] <ref>` works as a read-only preflight. It persists nothing to `OCX_HOME`. A missing repository exits 80. A missing tag exits 0 with only a warning, so a script must check the output.

## Sources

- ocx help output for 0.6.5: `ocx --help`, `ocx package {install,push,test,create,verify,sign,uninstall} --help`, `ocx index list --help`, `ocx config test --help`.
- Docs (ocx-sh/ocx, `website/src/content/docs/`): `guides/configure-ocx.mdx`, `guides/authenticate.mdx`, `guides/verify-installs.mdx`, `guides/clean-up.mdx`, `guides/serve-an-index.md`, `explanation/signing.mdx`, `explanation/storage.mdx`, `reference/environment.md`, `reference/configuration.md`, `reference/command-line/package-consuming.md`, `reference/command-line/package-publishing.md`.
- Source: `crates/ocx_config/src/loader.rs` (tiers, `OCX_NO_CONFIG`), `crates/ocx_config/src/home.rs` (`OCX_HOME`), `crates/ocx_config/src/env.rs` (`insecure_registries`), `crates/ocx_trust/src/lib.rs` (`pattern_matches`, `ScopeSpec::matches`), `crates/ocx_cli/src/exit/ocx_sign.rs` (verify exit-code mapping), `crates/ocx_oci/src/ssrf.rs`.
- Test tooling: `test/src/zot.py`, `test/src/runner.py` (isolated env), `test/docker-compose.yml`, `ocx.toml` (zot pinned as `ocx.sh/project-zot/zot:2.1.21`), `CONTRIBUTING.md`.
- Issue ocx-sh/ocx#670 (policy scope vs index name, open at research time).

## Findings

### 1. Isolation

- Config tiers, lowest to highest (docs `guides/configure-ocx.mdx`): system `/etc/ocx/config.toml`, user (macOS: the platform config dir, `XDG_CONFIG_HOME` not consulted), `$OCX_HOME/config.toml`, then the identity-gated managed snapshot, then `OCX_CONFIG`, then `--config`. Missing files are skipped silently.
- Source (`loader.rs`): with `OCX_NO_CONFIG=1` the loader reads only `system_path()` and prunes the rest: "`OCX_NO_CONFIG=1` prunes ambient config, not operator policy: the system file still loads". The reference says the managed snapshot and `OCX_MANAGED_CONFIG` are dropped too. An unreadable system file aborts with exit 78.
- Explicit `--config` and `OCX_CONFIG` paths still load under `OCX_NO_CONFIG`. Documented hermetic pattern: `OCX_NO_CONFIG=1 ocx --config ci.toml ...`. A missing explicit file exits 79.
- `OCX_HOME` (`home.rs`): used if set and non-empty, else the default dot dir in the home directory. Store, layers, blobs, index, symlinks, state (including `state/trust_root/`) and `sigstore/trusted-root.json` all live under it.
- Observed: with a fresh `OCX_HOME`, `ocx about` reports that home. `ocx --remote index list` left the directory empty (pure query, nothing persisted).
- Credentials are outside `OCX_HOME`. Order: `OCX_AUTH_<REGISTRY>_*` variables, then Docker config (`credHelpers`, `auths`, `credsStore`) through the Docker credential helper, so a macOS keychain helper can be called and may prompt. `DOCKER_CONFIG` redirects the directory. Setting any `OCX_AUTH_*` for a registry, or `OCX_AUTH_<REGISTRY>_TYPE=anonymous`, means no helper runs for it. The slug replaces every non-alphanumeric character with `_` (`ghcr.io` gives `ghcr_io`, `localhost:5000` gives `localhost_5000`).
- Other host state: the project walk finds an `ocx.toml` upward from the working directory (`OCX_NO_PROJECT=1` disables it). Upstream's own test runner (`test/src/runner.py`) sets `OCX_HOME`, `OCX_DEFAULT_REGISTRY`, `OCX_INSECURE_REGISTRIES`, `XDG_CONFIG_HOME` (its comment: keeps the host user config tier out) and a minimal `PATH`.
- Suggested env for the test: `OCX_HOME`, `OCX_NO_CONFIG=1`, `OCX_NO_PROJECT=1`, `DOCKER_CONFIG=<empty dir>`, `OCX_NO_UPDATE_CHECK=1` (variable exists per the CI note in the reference; not exercised).

### 2. Candidate install options

- `ocx package install --help`: "Install packages from a local or remote index". "Local" means the local index copy, not a local archive. Arguments are package identifiers only.
- `ocx package pull` and `ocx package exec` also take identifiers. Searching the repo for `oci-layout` found only design notes; `file://` appears only for index bases (`[registries."<ns>"] index = "file:///abs/path"`, `OCX_INDEX`, `--index`). A `file://` index resolves tags to digests; layer blobs still come from a registry.
- `ocx package test` (`package-publishing.md`): materializes layers into a temp dir or `-o DIR` (must not exist or be empty, same filesystem as `$OCX_HOME/layers/`), composes the env and runs a command or Starlark script. No registry round trip, but no install symlink, no `--link`, no verify step. Useful as a unit check, not as the install-path e2e.
- `ocx package push` over HTTP: Gated by `OCX_INSECURE_REGISTRIES` (comma-separated `host[:port]`, exact match, forwarded to children) or `[registries."<name>"] insecure = true`. Upstream's runner sets `OCX_INSECURE_REGISTRIES=localhost:<port>` and pushes to zot. Push inputs: archive layers plus `-m metadata.json` (the compiled form `package create -m` writes next to the archive), `-p <platform>`, `-i <repo:tag>`; `-p` and `-i` default from the build receipt written by `package create -i ... -p ...`. Use `--no-keep-tag` for ephemeral builds.
- The SSRF guard in `ssrf.rs` is documented for remote-controlled hosts (index pointers). A host typed on the command line is not covered by that text, and `trusted_hosts` exists per namespace if loopback is refused. Not tested here.
- Local registry options on macOS without Docker:
  - zot: upstream pins `ocx.sh/project-zot/zot:2.1.21` in `ocx.toml`, runs it with config `{"distSpecVersion":"1.1.1","storage":{"rootDirectory":...,"dedupe":true},"http":{"address":"127.0.0.1","port":"0"},"log":{"level":"info"}}` and parses the `kernel chosen port` log line (`test/src/zot.py`). It supports the Referrers API.
  - Distribution `registry` (Go): the upstream compose file uses `registry:2` only as a deliberate Referrers-negative fixture (exit 82). Fine for push and install of unsigned packages; not for signed ones. A Go toolchain exists on the dev machine, but building it was not tried.
  - OCX ships no registry of its own; the test suite relies on zot (install) and `registry:2` (Docker).
- Installing zot through OCX needs a first, published-style install into the test `OCX_HOME`. That step was denied by the sandbox classifier in this session, so no live run of zot was done.

### 3. Signatures in candidate mode

- Trust is opt-in per scope. A package outside every policy installs normally with an INFO or warning line that no policy covered it (`guides/verify-installs.mdx`). A policy covering the package makes `install` and `pull` verify before any layer download, fail-closed.
- Verify exit codes in the docs table: 77 identity or issuer mismatch, 78 trust-root or policy problem, 81 offline with no pinned Rekor key, 79 missing signature, 65 tampered bundle.
- Source (`ocx_sign.rs` tests): `NoSignaturesFound` maps to `ExitCode::NotFound` (79). `IssuerMismatch` maps to `PermissionDenied` (77), and so does `UnsignedRejectedByPolicy` (an unsigned SBOM attestation). So a test that asserts "unsigned" should expect 79 from `ocx package verify` on an unsigned package, and should confirm the slug `no_signatures_found` with `--format json` or the error text.
- To assert "unsigned" explicitly in candidate mode: run `ocx package verify --certificate-identity X --certificate-oidc-issuer Y localhost:PORT/repo:tag` and expect exit 79. Keyless verify may fetch the public TUF trust root unless a trusted-root file is supplied; with key mode (below) this should not be needed (not verified).
- Signing without OIDC: `ocx package push --sign --key <ref>` (or `ocx package sign --key <ref>`) signs with a key pair instead. Key ref forms: a path, `file://`, or `env://VAR`. The private key is encrypted, password from `OCX_KEY_PASSWORD`. Rekor upload is off by default in key mode. Format is cosign-style (cosign is available as an OCX package, `ocx.sh/sigstore/cosign`). Verification uses `{ kind = "key", key = "<public.pub>" }` in a `[[trust.policy]]` or `ocx package verify --key`.
- `--sign` is opt-in; a push without it signs nothing. There is no flag to "skip" verification except `--no-verify` or `OCX_NO_VERIFY` (prints a `warning:` line). Keyless signing needs a live Fulcio, Rekor and an OIDC token, so it is not usable for local candidates.
- Referrers: signatures are OCI referrers; a registry without the Referrers API and without the fallback index write exits 82.

### 4. Trust policy scoping

- Matching code (`crates/ocx_trust/src/lib.rs`): `pattern_matches(pattern, target)`: empty pattern is a catch-all; with a `*` it is `target.starts_with(literal prefix before *)`; without `*` it is `target == pattern || target.starts_with(pattern + "/")`. The target is "the canonical `registry/repository`". `ScopeSpec::matches` applies include then exclude (exclude wins).
- The string comparison has no alias or index resolution. Issue #670 shows the effect: a policy scoped `ghcr.io/<ns>/<pkg>` did not cover an install typed `ocx.sh/<ns>/<pkg>` (installed unverified with a warning), and a policy scoped `ocx.sh/...` applied but failed closed with a 401 on the referrers request. Both facts are from the issue report, not re-run here.
- Consequence for the e2e: type the same host in the ref and in the scope. Published mode: use `ghcr.io/...` refs and `ghcr.io/...` scopes. Candidate mode: refs `localhost:PORT/...` are uncovered by a `ghcr.io/` scope; add a separate policy for the local scope (key signer) or leave it unsigned and assert exit 79 with `verify`.
- Auto-verify reads only the operator `config.toml` tier (so the file given with `--config`), not a project `ocx.toml`.

### 5. `install --link`, uninstall and purge

- `--link <PATH>`: takes exactly one package. PATH "must be absent or a link an earlier `--link` wrote; anything else is refused (exit 65). Delete the link to release the package." It keeps the package from `ocx clean`. Read back with `--link` on `package which`, `package env`, `package exec`.
- `ocx package uninstall [--purge] [-d] <PACKAGE>...`: removes the candidate symlink and its back-reference; `--purge` also deletes the object when nothing else references it. Whether a leftover `--link` path blocks the purge was not tested; the docs say the link keeps the package alive, so delete the link first.
- Safest cleanup: the test owns a fresh `OCX_HOME`, so `rm -rf` of that directory is the cleanup. `ocx clean` was deliberately not run (it acts on the whole store and the project ledger). Docs warn not to run `clean` while other ocx commands run.

### 6. Preflight with `--remote index list`

- Observed on a published package (ghcr.io ref, fresh `OCX_HOME`, `OCX_NO_CONFIG=1`):
  - `ocx --remote index list ghcr.io/<ns>/<pkg>` prints the tags (floating `0`, `0.1`, the exact tag, `latest`).
  - `ocx --remote --format json index list --platforms ghcr.io/<ns>/<pkg>:<tag>` prints a JSON object keyed by ref with an array of platforms, for example `["darwin/arm64"]`. `--platforms` uses the tag in the identifier, or `latest`.
  - The index-named form `ocx.sh/<ns>/<pkg>` also lists platforms.
  - A repository that does not exist: exit 80 (registry authentication failed / denied).
  - A tag that does not exist: exit 0 with `warning: Tag '...' not found ... skipping`. A preflight script must test the output for the platform, not only the exit code.
- `--remote` is documented to persist nothing for pure queries; `OCX_HOME` stayed empty.

## negative

- No live run of zot, `ocx package push` to a local registry, `install --link` against it, or key signing. The sandbox denied installing and running a downloaded binary. All of those points rest on help text, docs, upstream test code and source.
- `uninstall --purge` while a `--link` path still exists was not tested.
- Not verified: whether the SSRF guard blocks a loopback registry typed directly on the command line; whether key-mode verification needs any Sigstore trust-root fetch; whether `OCX_NO_UPDATE_CHECK` is honoured in 0.6.5.
- Not verified: where the TUF cache lives for keyless verify (the docs list `state/trust_root/` under `OCX_HOME`; the TUF fetch location itself was not checked).
- The `/etc/ocx/config.toml` system tier cannot be disabled; its presence on a machine was not checked.
- Issue #670 behaviours are quoted from the report; not re-run (the issue was open).
- Keychain behaviour of the Docker credential helper was not exercised.
