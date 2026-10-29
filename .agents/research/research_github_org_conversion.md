# Research: converting the `extra-code` personal account into an organization

## Metadata

**Date:** 2026-10-29
**Domain:** GitHub account, release infrastructure
**Triggered by:** the question whether Parbake should live under an organization, before the first
claim in the OCX index fixes the namespace.
**Status:** not planned. Kept for a later migration.
**Expires:** 2027-04-29

## Direct Answer

- GitHub can turn a personal account into an organization ("Turn into an organization"). The
  account keeps its name, so `github.com/extra-code/…`, `ghcr.io/extra-code/…`, the Sigstore
  signing identities and every doc that names them stay valid.
- The step is irreversible. The converted account can no longer sign in. A second personal account
  becomes the organization's owner and carries the keys and tokens from then on.
- Claiming `ocx.sh/extra-code/*` now does not block a later conversion, because the name stays. It
  blocks only a move to a differently named organization: the index has no rename.
- A new organization under another name, such as `extraco-de`, is the alternative that keeps the
  personal account. It changes the registry paths, the signing identities and the index namespace.
- GitHub names may not contain a dot, and neither may OCX namespaces. `extraco.de` is not a valid
  name. An organization can show the domain as verified instead (DNS TXT record).

## Sources

- GitHub Docs, "Converting a personal account into an organization" (steps and prerequisites).
- GitHub Docs, "Personal account reference", section "Side effects of converting an account to an
  organization".
- GitHub Docs, "About permissions for GitHub Packages".
- OCX index docs, "Claim a Namespace" and "Contributing" (owners and the machine lane).
- `gh api` reads of the three repositories on 2026-10-29, listed under Inventory.

## Findings

### Prerequisites and steps

1. Create a second personal account. It signs in after the conversion and owns the organization.
2. The account to convert must not be a member of any organization. `extra-code` is in none.
3. Signed in as `extra-code`: Settings → Organizations → "Turn extra-code into an organization".
4. Enter the second account as organization owner, choose the Free plan, then Create Organization.

### Side effects GitHub documents

| Effect | Consequence here |
|---|---|
| The converted account can no longer sign in. | All work moves to the second account. |
| SSH keys, OAuth tokens and user information are not transferred. | Push key, SSH signing key and the `gh` login move to the second account. The `OCX_ANNOUNCE_TOKEN` personal access token has to be issued again by the second account and stored again in both `release` environments. |
| Commits stay, but are no longer linked to the account. | Commits link to the second account once it holds the commit email and the signing key. |
| Comments are attributed to the `ghost` user. | Earlier issue and pull request comments lose their author. |
| Forks of private repositories are deleted. | None: all three forks and repositories are public. |
| GitHub Apps are uninstalled. | None installed. |
| GitHub Actions is not enabled automatically. | Re-enable Actions and check the allow-list and SHA pinning in both repositories. |
| Stars, follows and gists are lost or frozen. | Not used. |
| An organization cannot be converted back. | One-way door. |

### What GitHub does not document

- **Container packages.** Container packages belong to the account, not to a repository. The
  account keeps its id through the conversion, so the packages most likely stay at
  `ghcr.io/extra-code/…`. No page states it. Verify before converting, for example with GitHub
  Support, or on a throwaway account.
- **Rulesets and environments.** Not covered. Rulesets bypass by repository role (admin), which an
  organization keeps. Environment reviewers name the user `extra-code`, which stops being a user.
- **Repository URLs.** Not stated, but the name does not change.

### OCX index ownership

The first claim records the owner as the identity behind the token: `extra-code` with its numeric
GitHub id. The index's machine lane auto-merges an announce only when the pull request author's id
is in `owners[]`. After a conversion, announces come from the second account's token. That account
is not an owner, so every announce would wait for a human review. Running the claim workflow again
with the second account's token adds it as an owner ("claiming an already-claimed package adds your
owners to the entry").

## Inventory on 2026-10-29

| Repository | Ties to the user account |
|---|---|
| `extra-code/parbake` | `release` environment reviewer `User:extra-code`; secret `OCX_ANNOUNCE_TOKEN` (the user's PAT) in `release`; variable `OCX_INDEX_FORK`; rulesets `main` and `release tags`, bypass `RepositoryRole:5` (admin); Actions allow-list with SHA pinning. |
| `extra-code/container` (fork of apple/container) | Same reviewer, secret and variable; rulesets `ocx tags` (admin bypass), `ocx-package` and `parbake`; default branch `ocx-package`; same Actions settings. |
| `extra-code/index` (fork of ocx-sh/index) | No environment or secret. Actions enabled with all actions allowed. |
| Registry | `ghcr.io/extra-code/container` and `ghcr.io/extra-code/parbake`, both linked to their repositories through `org.opencontainers.image.source`. |
| Local machine | `gh` signed in as `extra-code`; the SSH key used for push and commit signing; the git `allowedSignersFile`. |

## Checklist for a later conversion

Before:
1. Confirm with GitHub Support that container packages stay with the converted account.
2. Create the second personal account and enable two-factor authentication.
3. Add the commit email to it and verify it.
4. Add the SSH key to it twice: as an authentication key and as a signing key. Alternatively use a
   new key and update `user.signingkey` and the allowed signers file.
5. Note the current state: rulesets, environments, secrets, variables and Actions settings of each
   repository, as in the inventory above.

Convert:
6. Turn `extra-code` into an organization, with the second account as owner, on the Free plan.

After:
7. Sign in to `gh` as the second account (`gh auth login`).
8. Re-enable Actions where needed. Check the allow-list and SHA pinning of both repositories.
9. Set the second account as reviewer of the `release` environment in both repositories. Keep the
   branch and tag policies.
10. Issue a classic PAT with only `public_repo` from the second account. Store it as
    `OCX_ANNOUNCE_TOKEN` in both `release` environments.
11. Check that the rulesets still apply and that admin bypass works for the second account.
12. Check both packages: anonymous `ocx package description pull` and `ocx package verify` against
    `ghcr.io/extra-code/…`, and the package settings page, which should show the organization.
13. Run both claim workflows again with the new token, so the second account becomes an index owner.
14. Push a commit and check that GitHub shows it as verified and linked to the second account.
15. Optional: verify the domain `extraco.de` for the organization.

## negative

- No conversion was performed, and none was tried on a throwaway account.
- Package behaviour across a conversion stays unverified.
