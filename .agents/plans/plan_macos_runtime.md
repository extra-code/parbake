# Plan: macOS guests as containers on Apple container, up to CI jobs

## Status

- State:   in progress
- Updated: 2026-10-25
- Next:    step 7 (upstream) needs the organisation name; step 4 an Xcode download; step 5 can rerun with
  the identity of ADR 0010

---

## Overview

**Author:** Christian Semmelmann, with an automated planning assistant
**Date:** 2026-10-18
**Related ADRs:** [0001](../../docs/adr/adr_0001_overlay_per_container_on_an_asif_base.md) overlay
per container · [0002](../../docs/adr/adr_0002_guest_joins_the_container_network.md) container network
and DHCP · [0003](../../docs/adr/adr_0003_controlled_shutdown_over_ssh.md) shutdown over SSH ·
[0004](../../docs/adr/adr_0004_keychain_through_the_security_tool.md) keychain ·
[0005](../../docs/adr/adr_0005_macos_guests_stay_containers.md) containers, not machines ·
[0006](../../docs/adr/adr_0006_guest_agent_speaks_the_sandbox_context_protocol.md) agent protocol ·
[0008](../../docs/adr/adr_0008_what_a_ci_executor_can_rely_on.md) CI executor
**Related spec:** [spec_guest_agent.md](../../docs/specs/spec_guest_agent.md) (Draft)
**Related outside this repo:** the fork [extra-code/container](https://github.com/extra-code/container),
tag `parbake-804209b1` on apple/container `main` `804209b1`: the `[runtimeConfig]` hooks, the
kernel-flag warning, and the exit handler without `config.json`.

## Objective

Linux and macOS jobs side by side on one Mac mini through the same `container` CLI: a macOS job gets
a fresh guest from a shared base, runs as a CI user in a logged-in session, reaches Linux service
containers and corporate services, and is discarded afterwards.

Guests boot only from bundles that `parbake` installs from an IPSW (macOS 27 provisioning).
Importing disk images of other VM tools is out of scope.

## Done (2026-10-18)

| Area | State | Where |
|---|---|---|
| Install from IPSW onto an ASIF disk | done from the cached IPSW | `parbake install`, ADR 0001 |
| Provisioning without the Setup Assistant (macOS 27) | done; one SSH session adds keys and `GuestKey`, passwordless `shutdown`, optional `--tidy` | `parbake provision`, `parbake create` |
| Password in the keychain | done, through `security -i`, no dialogs | ADR 0004 |
| Overlay per container, new machine identifier | done | ADR 0001 |
| Container network, address in `container ls`, DHCP by the runtime | done; Linux container ↔ guest verified | ADR 0002 |
| Controlled stop over SSH | done, exit 0 | ADR 0003 |
| Fork rebased on apple/container `main`, containerization 0.53.0 | done | tag `parbake-804209b1` |

40 Swift tests green (`task check`). Booting a guest is manual (see Verification).

## Steps, in order

### 1. Guest agent over vsock — spec written, spike next

Replace SSH for readiness, `exec` and shutdown. vsock is not IP networking, so neither Local Network
privacy nor guest addresses matter (ADR 0002 context).

- Spec: `docs/specs/spec_guest_agent.md` (Draft, questions resolved), protocol choice ADR 0006: the
  SandboxContext subset of containerization on vsock port 1024, `Vminitd` on the host.
- Spike V-1 passed 2026-10-18 (`parbake agent-probe`): the agent target `parbake-agent` serves
  `Getenv` and `Sync` on vsock 1024 in a macOS 27 guest, `Vminitd` talks to it unchanged.
- C-002 to C-004 done 2026-10-18, V-2 passed at the agent (`agent-probe`): separate streams, exit
  code, stdin, signals, delete, Kill, SetTime. Open there: the PTY (`terminal: true` answers
  UNIMPLEMENTED; `posix_spawn` cannot give a controlling terminal) and the root path through
  `launchctl asuser` + `sudo -u`, untested until the agent runs as a LaunchDaemon (C-006).
- C-005 done 2026-10-19 (`GuestAgent` in `RuntimeMacOS`): readiness gate with the label
  `runtime-macos.readiness-timeout`, exec routes, stop through the agent (root, else `sudo -n` as the
  account), user mapping. V-2 through `container exec`, V-5 and V-6 passed, V-4 keychain half passed;
  the agent was installed by hand as a LaunchAgent of `runner` in container `mac1` for the test.
  Signals the CLI forwards to an exec process are lost in apple/container (#1941, open upstream).
- C-006 done 2026-10-19: the agent is a LaunchDaemon (root) installed by `provision` and by
  `parbake agent install`; `Agent` holds the version the agent answered. The peer-CID check runs in
  the agent's own vsock listener, which relays to gRPC on a root-only Unix socket. Verified on
  `~/VM4.bundle` (APFS clone of VM3 with the agent): exec as `runner` in its Aqua session with keychain
  access, `--user root`, stop as root, CID 3 refused. `provision` with the agent is unit-tested only.
- 2026-10-19: the image tool is renamed `parbake` (agent `parbake-agent`), chosen for its role
  (a base prepared ahead, finished per container) and without "macOS" in a product name. The
  plugin, labels, LaunchDaemon label and keychain service keep the runtime's name.
- 2026-10-21: layer bundles (`parbake layer`) verified with a Command Line Tools layer; the agent
  starts processes with umask 022; a save/restore spike shows restore refused under ad-hoc signing.
- 2026-10-21: step 3 decided in ADR 0008: the framework enforces two guests, an exec whose guest
  stopped fails instead of reporting a code, the agent sets `TMPDIR`.
- 2026-10-21: `exec -t` runs on a PTY that is the process's controlling terminal (V-3 passed).
- Open: the simulator half of V-4 (needs Xcode in a bundle), C-007 later.
- Agent: a `parbake-agent` executable target (arm64 macOS), a LaunchAgent in the CI user's session
  plus a LaunchDaemon for shutdown; installed by provisioning in the same SSH session.
- Host: `VZVirtioSocketDevice` listener in `MacOSVirtualMachine`; `RuntimeService` maps
  `createProcess`/`startProcess`/`kill`/`resize`/`wait` for non-init processes to the agent; readiness
  gates `container run -d` returning or is exposed for the executor.
- ADR 0003 amended 2026-10-19: shutdown through the agent, SSH as fallback.

### 2. `exec` stage A over SSH (only if step 1 takes long)

A stop-gap: `container exec` for the init container runs over SSH with `GuestKey`. Skip if step 1
lands soon.

### 3. What a CI executor needs from the runtime — done 2026-10-21, [ADR 0008](../../docs/adr/adr_0008_what_a_ci_executor_can_rely_on.md)

A readiness signal the caller can wait on; a documented limit of two macOS guests per host and who
enforces it (runtime or caller — decide); writable paths for builds and caches under the CI user's
home, since the system volume is read-only; distinct exit codes for a guest that failed to boot or
was stopped forcibly versus a job that failed.

### 4. Layered images — mechanism done 2026-10-21, [spec_layer_bundles](../../docs/specs/spec_layer_bundles.md)

`parbake layer` builds a layer bundle from a script; verified with the Command Line Tools as the
layer. Open: an Xcode layer (Xcode needs a download from a signed-in account, so the operator
provides the file), the cache layer on a network volume, image distribution (open decision 2).
Once distribution is decided: how a container names its bundle, by the `runtime-macos.bundle` label as
today, by opaque `runtimeData` (apple/container#1569), or by a passthrough flag.


macOS base (ASIF, read-only) → Xcode layer (read-only) → overlay per job; at most three levels
(Apple: keep stacks shallow). Needs a way to produce the Xcode layer: install Xcode in an overlay on
the base and keep that overlay as the next read-only layer. Cache layer for a base on a network
volume. Then the image distribution question (open decision 2).

### 5. Save and restore state spike — restore blocked

`parbake state-probe` saved a running guest, but restore failed across tested combinations of
instance, overlay and machine identifier with a Virtualization.framework error. The failure also
occurred without an overlay. The test used ad-hoc signing; whether saved state depends on signing
identity remains unverified. Next: rerun signed with the identity of ADR 0010
(`PARBAKE_CODESIGN_IDENTITY`), on a disposable clone. If restore works, decide whether restored
containers may share one machine identifier, since restore requires the saved configuration.


`saveMachineStateTo`/`restoreMachineStateFrom` for a booted, logged-in guest: compare startup from a
saved state with a cold boot, and check whether a restored guest on a fresh overlay is consistent.

### 6. Provisioning from a TOML file — done 2026-10-21

`parbake create --config` with `[account]` and `[guest]` (tidy, agent, sudo, scripts); unknown keys
fail, the command line wins.


Account, keys, tidy, sudo rules, packages from a file instead of flags, so image pipelines are
declarative.

### 7. Upstream

Publish the Discussion at apple/container (organisation name: open decision 1), then a PR with the
`[runtimeConfig]` hooks and the exit-handler fix. The Discussion draft is kept outside the repository;
move its permalinks to the fork's base before posting. Run the fork's integration tests before the PR. Rebase the fork on `main` before each
step; keep the plugin's containerization pin equal to `main`'s `scVersion`.

### Side track

- An SSH entry by name for macOS guests in `parbake` (ADR 0005 conveniences).
- Host directories in the guest: the runtime refuses `--volume` and `--mount`, so a cache that
  outlives a job has no shared host directory. Approach: a `VZVirtioFileSystemDeviceConfiguration`
  from the container's mounts in bootstrap, and `mount_virtiofs` in the guest through the agent at
  the requested path. Write a spec first, then test with a cache directory on the host.
- `parbake agent install … | tail -1` printed `See 'parbake --help'` twice in script runs although
  the install worked; two direct reruns were clean. If it recurs, capture the full output.
- A distinct exit code for a guest lost during `exec` needs apple/container to pass a failure kind
  through `container exec`, an upstream change. ADR 0008 states the current rule.

## Open decisions (the user's)

1. Under which organisation name do the Discussion and the PR go out? The fork lives under `extra-code`.
2. Image distribution: OCI artifacts in a registry or `container`'s content store?
3. A Developer ID for distributed builds? An Apple Development identity covers local use and the
   keychain ACL (ADR 0010).
4. `parbake create --config` reads TOML through TOMLDecoder, the first non-Apple dependency besides
   gRPC. Keep it, or switch the format to JSON (Foundation only)?

## Verification

```bash
task check                                          # build, sign, 51 tests
"$(task bin-path)/parbake" create --bundle ~/VMn.bundle --username runner --keychain --tidy \
  --authorized-key ~/.ssh/<key>.pub
scripts/dev-env.sh up -y                            # stops the installed services; check `container ls -q` first
scripts/dev-env.sh run ~/VM6.bundle --name mac6
scripts/dev-env.sh container ls                     # the guest's assigned address
ssh -i ~/.ssh/<key> runner@<address> sw_vers        # confirm guest access
scripts/dev-env.sh container stop mac6              # log: "guest accepted the shutdown through the agent as root", exit 0
scripts/dev-env.sh container rm mac6
scripts/dev-env.sh down                             # restores the installed services
```

Logs: `~/.container-macos-dev/logs/container-runtime-macos-<id>.log`. The fork's unit tests:
`make test` in `.build/dev-env/container`.

## Environment notes

- Validation used internal and external APFS volumes. Exact mount names, paths, device models,
  throughput and image sizes are omitted.
- The bundles were provisioned, and one was rebuilt with `--replace`. No container used either
  bundle during validation.
- Keychain validation used a provisioned guest account. Account names and item-specific details
  are omitted.
- Development data stays under the configured user data root. Local Git signing paths and identity
  details are omitted.
- Virtualization.framework limits each host to two running macOS guests.

## Risks

- Apple declines the hooks; fallback is a small maintained patch set.
- SSH-based stop and readiness depend on the guest's sshd until step 1.
- Ad-hoc signing changes identity on every build; anything bound to code identity (Local Network,
  keychain ACLs) re-prompts.
