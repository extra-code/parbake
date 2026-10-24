// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerNetworkClient
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import Foundation
import Logging
import RuntimeMacOS
import Virtualization
import vmnet

extension RuntimeEnvironment {
    /// The environment of the installed helper: real bundles, Virtualization.framework, vmnet and
    /// the host's lease file.
    static func live(log: Logger) -> RuntimeEnvironment {
        RuntimeEnvironment(
            loadConfiguration: { try RuntimeConfiguration.readRuntimeConfiguration(from: $0) },
            validateBundlePath: { try BundlePathPolicy(home: FileManager.default.homeDirectoryForCurrentUser).validate($0) },
            openInstance: { bundle, instance, resetOverlay in
                let source = try MacOSVMBundle(url: bundle)
                let opened =
                    FileManager.default.fileExists(atPath: instance.path)
                    ? try MacOSVMBundle(url: instance)
                    : try source.instance(at: instance)
                if resetOverlay {
                    try opened.resetOverlay(from: source)
                }
                return opened
            },
            makeGuest: { bundle, cpus, memory, network in
                let machine = try MacOSVirtualMachine(
                    bundle: bundle,
                    cpus: cpus,
                    memoryInBytes: memory,
                    network: (network?.handle as? LiveNetwork)?.guestNetwork
                )
                return (machine, GuestAgent(virtualMachine: machine))
            },
            runShell: { shell, command, address, timeout in
                // Cancelling the calling task terminates ssh.
                await shell.runCancellable(command, on: address, timeout: timeout)
            },
            allocateNetwork: { message, configuration in
                try await LiveNetwork.allocate(message, configuration: configuration, log: log)
            },
            releaseNetwork: { ($0.handle as? LiveNetwork)?.release() },
            leaseAddress: { DHCPLeases.currentAddress(for: $0) },
            now: { Date() }
        )
    }
}

/// The vmnet network reference, DHCP server and XPC session behind one `AllocatedNetwork`.
private final class LiveNetwork: @unchecked Sendable {
    let guestNetwork: GuestNetwork
    private let session: XPCClientSession
    private let dhcpServer: GuestDHCPServer

    private init(guestNetwork: GuestNetwork, session: XPCClientSession, dhcpServer: GuestDHCPServer) {
        self.guestNetwork = guestNetwork
        self.session = session
        self.dhcpServer = dhcpServer
    }

    func release() {
        dhcpServer.stop()
        session.close()
    }

    /// Allocates the guest's address on the container's first network, or returns nil when the
    /// container has no network; the guest then uses Virtualization.framework NAT.
    static func allocate(_ message: XPCMessage, configuration: ContainerConfiguration, log: Logger) async throws -> AllocatedNetwork? {
        let infos = (try? message.networkBootstrapInfos()) ?? []
        guard let info = infos.first, let attachmentConfiguration = configuration.networks.first else {
            return nil
        }
        let client = NetworkClient(id: attachmentConfiguration.network, plugin: info.plugin)
        let session = client.connect()
        do {
            let (attachment, additionalData) = try await client.allocate(
                hostname: attachmentConfiguration.options.hostname,
                macAddress: attachmentConfiguration.options.macAddress,
                on: session
            )
            guard let additionalData else {
                throw ContainerizationError(.invalidState, message: "network \(attachment.network) returned no vmnet network reference")
            }
            var status: vmnet_return_t = .VMNET_SUCCESS
            guard let reference = vmnet_network_create_with_serialization(additionalData.underlying, &status) else {
                throw ContainerizationError(.invalidState, message: "cannot deserialize the vmnet network reference, status \(status)")
            }
            let macAddress = attachment.macAddress?.description ?? VZMACAddress.randomLocallyAdministered().string
            let server = try startDHCPServer(on: reference, attachment: attachment, macAddress: macAddress, configuration: configuration, log: log)
            let network = LiveNetwork(
                guestNetwork: GuestNetwork(reference: reference, macAddress: macAddress), session: session, dhcpServer: server)
            return AllocatedNetwork(attachment: attachment, handle: network)
        } catch {
            session.close()
            throw error
        }
    }

    /// Starts the DHCP server that gives the guest with `macAddress` the attachment's address,
    /// gateway and DNS servers.
    private static func startDHCPServer(
        on network: vmnet_network_ref, attachment: Attachment, macAddress: String, configuration: ContainerConfiguration, log: Logger
    ) throws -> GuestDHCPServer {
        let nameservers = configuration.dns.flatMap { $0.nameservers.isEmpty ? nil : $0.nameservers } ?? [attachment.ipv4Gateway.description]
        guard let clientMAC = DHCPMessage.mac(macAddress),
            let address = DHCPMessage.ipv4(attachment.ipv4Address.address.description),
            let gateway = DHCPMessage.ipv4(attachment.ipv4Gateway.description)
        else {
            throw ContainerizationError(.invalidArgument, message: "invalid network attachment \(attachment.ipv4Address) via \(attachment.ipv4Gateway)")
        }
        let lease = DHCPMessage.Lease(
            clientMAC: clientMAC,
            address: address,
            subnetMask: DHCPMessage.mask(prefixLength: Int(attachment.ipv4Address.prefix.length)),
            gateway: gateway,
            nameservers: nameservers.compactMap(DHCPMessage.ipv4)
        )
        let server = GuestDHCPServer(lease: lease) { request, reply in
            log.info("answered the guest's DHCP request", metadata: ["request": "\(request)", "reply": "\(reply)"])
        }
        try server.start(on: network)
        return server
    }
}
