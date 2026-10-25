# Research: Parbake repo archaeology

## Metadata

**Date:** 2026-10-22
**Domain:** testing
**Triggered by:** `.agents/discussions/release-audit.md` — repo archaeology lane
**Expires:** 2027-01-22

## Direct Answer

- Main holds 27 curated commits from 2026-10-02 to 2026-10-21. The original history is on `backup/main-pre-rewrite`.
- No commit reverts another. Every change of design went forward and is recorded in an ADR.
- Open items cluster around a few topics:
  - save/restore (plan step 5);
  - the Xcode layer;
  - image distribution;
  - the upstream organisation name;
  - the cache layer for a base on a network volume.
- All validations ran on one host, the author's, with macOS 27 and an encrypted external APFS volume.

## Key Findings

### Replaced approaches

| From | To | Where recorded |
|---|---|---|
| Keychain through the Security framework | `security -i` with `-A` | ADR 0004 |
| Raw disk, plus an ASIF fallback | ASIF only on macOS 27 | ADR 0007; ADR 0001 superseded for the raw path |
| `--ipsw` and `parbake ipsw-url` | `--restore-image` and `create --replace` | `docs/specs/spec_bundle_rebuild.md` |
| Readiness, exec and shutdown over SSH | the vsock agent, SSH only as the shutdown fallback | ADR 0003 amended 2026-10-19 |
| VZ NAT | vmnet plus Parbake's own DHCP server | ADR 0002 |
| `macos-vm` | `parbake` | the plugin, labels and keychain service keep the old name |
| `exec -t` unsupported | a PTY in the agent | `docs/specs/spec_guest_agent.md` V-3 |

### Open items

- **Network-volume cache layer:** `docs/adr/adr_0001_overlay_per_container_on_an_asif_base.md:127` is unchecked. `.agents/plans/plan_macos_runtime.md:100-103` keeps it open.
- **Save/restore, plan step 5** (`.agents/plans/plan_macos_runtime.md:112-122`):
  - It is blocked. Every restore failed with `VZErrorDomain` code 12 under ad-hoc signing.
  - The working hypothesis is that saved state is bound to the signing identity. It is not verified, because testing it needs a Developer ID.
- **V-4 and the Xcode layer:** the simulator half of V-4 and the Xcode layer both need an Xcode download that requires signing in.
- **Plan open decisions:**
  - 1: the organisation name. Now settled outside the plan: `extra-code`.
  - 2: image distribution, through an OCI registry or the content store.
- **Upstream:**
  - Signals sent to `exec` are lost (apple/container #1941).
  - The fork's commits for the runtime-plugin hooks are not upstream.
  - Containerization is pinned at 0.52.0.
- **Spec status:**
  - `docs/specs/spec_guest_agent.md:5` says Draft, while its Open Questions section says "None".
  - The Approval boxes are unchecked in all three specs.
- **`provision` with the agent:** covered only by unit tests.

### Churn, as the number of commits touching each file

| File | Commits |
|---|---|
| README.md | 20 |
| MacOSVirtualMachine.swift | 11 |
| RuntimeService.swift | 10 |
| spec_guest_agent.md | 9 |
| Package.swift | 9 |
| MacOSVMBundle.swift | 8 |
| GuestProvisioningTests | 7 |
| architecture.md | 6 |
| GuestPreparation.swift | 5 |
| GuestAgent.swift | 5 |

Measured by churn, the most fragile areas are the VM lifecycle with its service layer, bundle and disk handling, and the agent's process code.

### Recorded validations

All of them ran in one development environment:

- the guest agent's V-1 to V-6 (2026-10-18 to 2026-10-21), except the simulator half of V-4;
- bundle rebuild V-5 on an encrypted external APFS volume;
- layer bundles V-1 to V-4 (2026-10-21);
- the checks in ADR 0008;
- DHCP and DNS failover behavior when the IPv6 resolver stays silent.

There is no run on a second host, none in CI and none under a Developer ID.

### Retro

The only entries are two near-identical pitfalls about the signing key, both low severity.

## negative

- No reverts, no TODO or FIXME left in the docs, and no ADR rejected or deprecated.

## leads

- Release signing may change runtime behaviour. Plan step 5 already shows save/restore depending on the signing identity.
- README and `docs/architecture.md` have the most churn. Check them for stale wording: macOS 26, raw disk, `--ipsw`, `macos-vm`, and SSH used for exec.
- Check whether `scripts/create-vm-bundle.sh` is still needed now that `parbake` exists.
