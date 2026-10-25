# Research: Field pitfalls for macOS guests on Virtualization.framework

## Metadata

**Date:** 2026-10-22
**Domain:** testing
**Triggered by:** `.agents/discussions/release-audit.md` — community lane
**Expires:** 2027-04-22

The issue trackers on GitHub were not searched directly. The evidence comes mainly from the Apple Developer Forums.

## Direct Answer

The audit and the manual end-to-end (E2E) test should check six areas explicitly:

1. Leaked VM slots under the two-VM limit.
2. Keychain access and Virtualization.framework (VZ) without a GUI session.
3. vmnet state when the network's last interface leaves.
4. The shutdown path.
5. Version skew between host and guest.
6. Space accounting for APFS clones and ASIF images.

## Key Findings

### Two-VM limit and leaked slots

Parbake component: `MacOSVirtualMachine` and the limit for a third guest.

- **What is reported:**
  - After the guest shuts itself down, the VM reports `.stopped`, but the next `start()` fails with code 6, `VZErrorVirtualMachineLimitExceeded`.
  - Only rebooting the host helps. Tart users report the same.
  - Seen on macOS 26.5 and still open at Apple (FB22967193). [thread 830119](https://developer.apple.com/forums/thread/830119)
- **Check:**
  - Run N create/shutdown cycles through the guest's own `shutdown -h now`, and confirm that start still succeeds.
  - When code 6 appears, the error must be actionable, mention a possible host reboot, and not be retried in a loop.

### Keychain and the GUI session

Parbake component: `GuestCredentials` and VM start on a CI host.

- **What is reported:**
  - Creating and starting a VM over SSH without a GUI login failed with `VZErrorDomain` -9, "Failed to get current host key" (2026, macOS 26.4.1). [thread 822670](https://developer.apple.com/forums/thread/822670)
  - Apple DTS says VZ is not daemon-safe.
  - Keychain access over SSH returns -25308, "User interaction is not allowed". [thread 97091](https://developer.apple.com/forums/thread/97091) is from 2018 and old.
- **Check:** run the flow from a LaunchAgent and over SSH, with the keychain locked. The error must be clear and must not be swallowed.

### vmnet and DHCP

Parbake component: `GuestDHCPServer` and the container network.

- **What is reported:**
  - When the last interface leaves a `vmnet_network_ref`, its DHCP reservations and port forwards are lost.
  - If the only guest restarts, the interface is created again about 1 s later (macOS 26.6.2 and 27.0; FB24895271; apple/container#2051). [thread 847642](https://developer.apple.com/forums/thread/847642)
  - macOS's own DHCP server gives 24-hour leases on a /24, which run out when CI creates many guests. [softnet](https://github.com/cirruslabs/softnet/blob/main/README.md)
- **Check:**
  - Restart the only guest on a network, then tear the network down in the order apple/container uses.
  - Confirm the guest keeps its address and that no address is reused while the old guest is still alive.

### Shutdown

Parbake component: the agent's shutdown and the SSH fallback.

- **What is reported:**
  - macOS guests ignore `requestStop`, while `sudo shutdown -h now` works. [macosvm](https://github.com/jefferyq2/macosvm) is old (2021).
- **Check:**
  - Passwordless sudo, the timeout, and the fallback to a forced stop.
  - What happens to the guest when the owning process dies. [thread 849681](https://developer.apple.com/forums/thread/849681) was not read.

### Version skew on macOS 27

Parbake component: `parbake install` and `create`.

- **What is reported:**
  - Installing a macOS 27 guest from a 26.6 host fails; build on a 27 host instead. [thread 829576](https://developer.apple.com/forums/thread/829576)
  - A black screen appears after updating a guest to 26.7 on a 27.0 host. [thread 847322](https://developer.apple.com/forums/thread/847322)
  - The installer keeps working in the background after create returns; Tart's Packer plugin adds `create_grace_time` for that. [packer](https://developer.hashicorp.com/packer/integrations/cirruslabs/tart/v1.9.0/components/builder/tart)
- **Check:**
  - Record the host and guest version pair.
  - Make sure the base is used only after the install has finished.

### Disk: ASIF and APFS clones

Parbake component: the bundle and its overlays.

- **What is reported:**
  - No corruption reports were found for ASIF. [Eclectic Light](https://eclecticlight.co/2025/06/12/macos-tahoe-brings-a-new-disk-image-format/)
  - Deleting a clone frees nothing while the original still shares its blocks, and adding up file sizes gives a misleading total. [Eclectic Light 2023](https://eclecticlight.co/2023/05/04/cow-and-clones-how-they-save-space-and-ssd-wear/) is old.
- **Check:**
  - Cleaning up overlays after a crash.
  - A disk filling up while the guest writes.
  - Space estimates that do not simply add up file sizes.

## negative

No field reports were found for these topics:

- races between vsock and agent readiness;
- the DNS delay when IPv6 stays silent;
- ASIF corruption;
- SSH host keys or sudo in macOS guests.

That reflects how far the search reached, not that these problems are absent.

## leads

- Search the GitHub trackers directly: cirruslabs/tart, apple/container#2051, apple/containerization (vsock) and lima-vm/lima.
- Read threads 849681 and 822025 in full.
