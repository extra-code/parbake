# ADR: The guest joins the container's vmnet network, and the runtime answers its DHCP

## Metadata

**Status:** Accepted
**Date:** 2026-10-18
**Deciders:** Christian Semmelmann
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**

- [x] Decision follows this project's stated architectural conventions / golden path
- [ ] OR the deviation is justified in the Rationale section below

**Domain Tags:** networking, virtualization, security
**Supersedes:** N/A
**Superseded By:** N/A

## Context

The guest used `VZNATNetworkDeviceAttachment`. It got an address from macOS's `bootpd` in a second
shared network (`192.168.65.0/24` while `container` held `192.168.64.0/24`), `container ls` showed no
address, Linux containers could not reach it, and host-side networking set up for `container`'s
network (`bridge100`, `192.168.64.0/24`) did not apply to it.

The Linux runtime allocates each attachment from the network plugin (`NetworkClient.allocate`) and
attaches the guest with the vmnet network reference transferred over XPC
(`vmnet_network_create_with_serialization`). `container`'s vmnet networks disable DHCP
(`vmnet_network_configuration_disable_dhcp`); Linux guests get a static address from vminitd.

Measured on this host, 2026-10-18:

- A macOS guest attached to the `default` network got only `169.254.x` over IPv4, and IPv6 addresses
  from the network's router advertisement.
- Finding it by MAC address through `ndp -an` worked from a terminal and failed from any process
  without Local Network permission: the neighbour table it read lacked every other host's entries,
  and multicast `ping6` reached nothing. The ad-hoc signed plugin is not in the Local Network list,
  and every rebuild is a new identity there; a headless CI host has nobody to approve it.
- A process signed with `com.apple.security.virtualization` started an interface on a vmnet network
  with `vmnet_interface_start_with_network`, without root.
- Unicast SSH from the plugin to a guest's vmnet address worked.

## Decision Drivers

- `container ls` shows the guest's address; macOS guests and Linux containers share a network.
- macOS guests share the network, subnet and bridge of `container`'s Linux guests.
- No Local Network approval, no root, no change to the guest image.

## Considered Options

### Option 1: Keep Virtualization.framework NAT

| Pros | Cons |
|------|------|
| Works today, DHCP from `bootpd` | Separate network and bridge, no address in `container ls` |

### Option 2: Join the network, configure the address over SSH after IPv6 neighbour discovery

| Pros | Cons |
|------|------|
| Uses tools in the guest | Neighbour table and multicast need Local Network permission per binary identity |
| | Needs the guest key and passwordless `networksetup` |

### Option 3: Join the network, answer the guest's DHCP from an own vmnet interface (chosen)

| Pros | Cons |
|------|------|
| Ethernet frames on the vmnet network, no Local Network permission | A small DHCP server in the runtime |
| Any guest image, provisioned or not | The server identifier is the gateway, which the runtime does not own |

## Decision Outcome

**Option 3.** In bootstrap the runtime allocates the guest's address and MAC address on the
container's first network, attaches the guest through `VZVmnetNetworkDeviceAttachment`, and reports
the attachment in its snapshot. `GuestDHCPServer` starts an interface on the same network and answers
DISCOVER and REQUEST from the guest's MAC address with the allocated address, the gateway and the DNS
servers, as broadcasts, with an infinite lease, so the guest never renews by unicast to the gateway.
A container without a network, or a host earlier than macOS 26, keeps NAT.

### Consequences

**Positive:**

- `container ls` lists the guest's address; Linux containers and the guest reach each other.
- Host-side rules written for `container`'s network apply to the guest's IPv4 traffic as they are.

**Negative:**

- The guest's first DNS server is the host's IPv6 link-local address from the router advertisement,
  ahead of the IPv4 resolver the DHCP reply names; host-side DNS handling for IPv4 only does not see
  those queries.

**Risks:**

- A REQUEST for another address is NAKed; a guest that keeps a stale lease from an earlier boot
  falls back to DISCOVER.

## Validation

- [x] `DHCPMessageTests`: offer and ack carry address, mask, router, DNS and infinite lease; another
      client gets no reply; non-DHCP frames are ignored.
- [x] On this host: OFFER and ACK within 6 s of the start; HTTPS egress; a Linux container and the
      guest reach each other; stop over SSH at the allocated address.
- [x] Where the guest's DNS queries go when the network's IPv6 resolver does not answer, measured
      2026-10-21 with tcpdump in the guest: `scutil --dns` lists the host's IPv6 link-local address
      first and the DHCP reply's IPv4 resolver second. Every lookup went to the IPv6 address and
      took 42 ms. With outgoing IPv6 DNS dropped by pf in the guest, the first lookup reached the
      IPv4 resolver after 2.2 s, and the next one went to it directly in 70 ms. An IPv4-only DNS
      path therefore sees every query once the IPv6 resolver stops answering, at a cost of about
      2 s for the first lookup.

## Links

- Code: `Sources/RuntimeMacOS/GuestDHCPServer.swift`, `Sources/RuntimeMacOS/DHCPMessage.swift`

## Changelog

- 2026-10-18 — Initial version.
- 2026-10-21 — DNS fallback to the IPv4 resolver measured.
