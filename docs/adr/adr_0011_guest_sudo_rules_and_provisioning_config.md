<!-- doc_type: explanation -->
# ADR: Guest sudo rules are absolute command paths. The README keys table specifies `--config`

## Metadata

**Status:** Accepted
**Date:** 2026-10-22
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** security, provisioning
**Supersedes:** N/A
**Superseded By:** N/A

## Context

[ADR 0003](adr_0003_controlled_shutdown_over_ssh.md) lets the guest account run `/sbin/shutdown`
without a password, through `/etc/sudoers.d/parbake`. `--sudo` and `[guest] sudo` add more
`NOPASSWD` rules to that file. Each value was a free string that went into the file as written.
A value could carry any sudoers syntax: arguments, wildcards, `ALL`, a second command after a comma.

`--script` and `[guest] scripts` run shell scripts as root in the guest, through the guest agent, after
provisioning. The `--config` file that carries both keys had no specification.

## Decision Drivers

- A rule the operator writes does what the operator reads in it, and nothing more.
- A reviewer reads the rule list of a bundle in one pass.
- Existing uses, such as `/usr/sbin/softwareupdate`, keep working.
- The shutdown rule of ADR 0003 stays.

## Considered Options

### Option 1: Remove `--sudo` and `[guest] sudo`

| Pros | Cons |
|------|------|
| No rule beyond `/sbin/shutdown` | A job that needs one root command has no way to get it except a script |
| Nothing to validate | Breaks bundles built with `--sudo` |

### Option 2: Keep it with absolute command paths only (chosen)

| Pros | Cons |
|------|------|
| Each rule names one program, with no arguments and no wildcards | A rule cannot narrow a command to one argument list |
| A short pattern is checked on the host before the download | A command with a space in its path is refused |
| Existing uses keep working | |

### Option 3: Keep free sudoers syntax

| Pros | Cons |
|------|------|
| Every sudoers feature works | A comma, `ALL` or a wildcard widens a rule beyond what it seems to say |
| No change | A typo can break `/etc/sudoers.d/parbake` for the whole file |

## Decision Outcome

**Option 2.** A sudo rule is one absolute command path. The whole value must match
`\A/[A-Za-z0-9._/+-]+\z`. The check runs before the download, with the other input checks of
`parbake create`. A value that does not match exits 64 and names the value.

The README [keys table](../../README.md#configuration-file) is the specification of `--config`
and `--script`: the keys, their types, the path rules and the command-line equivalents. This ADR
does not repeat it.

### Trust boundary

The operator who builds the bundle owns its guest. The bundle's disk image already holds everything
in the guest, and `--script` runs as root there. A sudo rule does not widen that trust.
It widens what a job can do. The job runs as the CI account, and the rule lets that account run the
named program as root without a password. Grant only programs a job needs, and read the rule list of
a bundle as part of its review.

### Consequences

**Positive:**

- A rule is one program. The list of a bundle reads as a list of programs.
- A malformed rule fails on the host in seconds, not in a guest after the download.

**Negative:**

- A rule cannot limit a program to certain arguments. A job that needs that wraps the call in a script
  that the operator installs in the guest.

**Risks:**

- A permitted program can itself run other commands as root, for example a shell or an editor.
  The pattern checks the shape of the rule, not the program's power.

## Validation

- [ ] `SudoCommand` accepts `/usr/sbin/softwareupdate` and refuses `softwareupdate`,
  `/bin/ls *`, `/bin/ls, /bin/sh` and a value with a newline.
- [ ] `parbake create --sudo 'ls'` exits 64 before the download.
- [ ] `/etc/sudoers.d/parbake` in a provisioned guest holds the shutdown rule and one line per
  `--sudo` value.

## Links

- [ADR 0003](adr_0003_controlled_shutdown_over_ssh.md)
- [README, configuration file](../../README.md#configuration-file)

## Changelog

- 2026-10-22: Initial version.
