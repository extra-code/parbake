// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import Foundation
import RuntimeMacOS

/// A guest address on the container network, held until `RuntimeEnvironment.releaseNetwork` runs.
struct AllocatedNetwork: Sendable {
    /// The address, gateway and MAC address the container network gave the guest.
    let attachment: Attachment
    /// What the environment needs to release the allocation again; only that environment reads it.
    let handle: any Sendable
}

/// Everything `RuntimeService` takes from the host: files, the virtualization framework, the
/// container network and the clock. Tests replace the closures.
struct RuntimeEnvironment: Sendable {
    /// Reads the runtime configuration the container's root holds.
    var loadConfiguration: @Sendable (_ root: URL) throws -> RuntimeConfiguration
    /// Resolves the bundle label to the bundle directory, or throws the reason it is refused.
    var validateBundlePath: @Sendable (_ path: String) throws -> URL
    /// Opens the container's instance of `bundle` at `instance`, creating it on first use; with
    /// `resetOverlay` the instance starts over from the bundle.
    var openInstance: @Sendable (_ bundle: URL, _ instance: URL, _ resetOverlay: Bool) throws -> MacOSVMBundle
    /// Builds the guest machine and its agent connection; throws `RuntimeFailure.incompatibleOverlay`
    /// when the instance's overlay no longer stacks on the bundle.
    var makeGuest:
        @Sendable (_ bundle: MacOSVMBundle, _ cpus: Int, _ memory: UInt64, _ network: AllocatedNetwork?) throws
            -> (machine: any GuestMachine, agent: any GuestAgentClient)
    /// Runs `command` in the guest at `address` over SSH.
    var runShell: @Sendable (_ shell: GuestShell, _ command: String, _ address: String, _ timeout: Duration) async -> GuestShell.Result
    /// Allocates the guest's address on the container's first network, or returns nil when the
    /// container has no network.
    var allocateNetwork: @Sendable (_ message: XPCMessage, _ configuration: ContainerConfiguration) async throws -> AllocatedNetwork?
    var releaseNetwork: @Sendable (_ network: AllocatedNetwork) async -> Void
    /// The address of the guest's current DHCP lease on the host's NAT, if any.
    var leaseAddress: @Sendable (_ macAddress: String) -> String?
    var now: @Sendable () -> Date
}
