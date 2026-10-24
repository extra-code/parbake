// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import vmnet

/// Answers the DHCP requests of one guest on a vmnet network with its allocated address.
///
/// The server starts its own interface on the network, reads the frames there and writes a reply
/// to every DISCOVER and REQUEST from the guest's MAC address. It needs the virtualization
/// entitlement, and no access to the host's local network.
public final class GuestDHCPServer: @unchecked Sendable {
    private let lease: DHCPMessage.Lease
    private let onReply: @Sendable (DHCPMessage.Kind, DHCPMessage.Kind) -> Void
    private let queue = DispatchQueue(label: "container-runtime-macos.dhcp")
    private var interface: interface_ref?
    private var serverMAC: [UInt8] = []
    private var maxPacketSize = 1518

    /// Creates a server for `lease`; `onReply` receives the kind of each request and of its reply.
    public init(lease: DHCPMessage.Lease, onReply: @escaping @Sendable (DHCPMessage.Kind, DHCPMessage.Kind) -> Void = { _, _ in }) {
        self.lease = lease
        self.onReply = onReply
    }

    /// Starts the server's interface on `network`.
    public func start(on network: vmnet_network_ref) throws {
        let description = xpc_dictionary_create(nil, nil, 0)
        let started = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: vmnet_return_t = .VMNET_FAILURE
        nonisolated(unsafe) var mac: [UInt8] = []
        nonisolated(unsafe) var packetSize = 1518
        let interface = vmnet_interface_start_with_network(network, description, queue) { result, parameters in
            status = result
            if let parameters {
                let address = xpc_dictionary_get_string(parameters, vmnet_mac_address_key).map { String(cString: $0) }
                let size = xpc_dictionary_get_uint64(parameters, vmnet_max_packet_size_key)
                let settings = Self.interfaceSettings(macAddress: address, maxPacketSize: size, defaultPacketSize: packetSize)
                mac = settings.mac ?? mac
                packetSize = settings.packetSize
            }
            started.signal()
        }
        guard let interface, started.wait(timeout: .now() + 10) == .success, status == .VMNET_SUCCESS, mac.count == 6 else {
            throw Self.startFailure(status)
        }
        queue.sync {
            self.interface = interface
            self.serverMAC = mac
            self.maxPacketSize = packetSize
        }
        let eventStatus = vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { [weak self] _, _ in
            self?.readFrames()
        }
        guard eventStatus == .VMNET_SUCCESS else {
            stop()
            throw Self.watchFailure(eventStatus)
        }
    }

    static func startFailure(_ status: vmnet_return_t) -> RuntimeFailure {
        .internalError("failed to start the DHCP interface on the vmnet network, status \(status.rawValue)")
    }

    static func watchFailure(_ status: vmnet_return_t) -> RuntimeFailure {
        .internalError("failed to watch the DHCP interface, status \(status.rawValue)")
    }

    /// Stops the server's interface.
    public func stop() {
        queue.sync {
            guard let interface else {
                return
            }
            _ = vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, nil, nil)
            _ = vmnet_stop_interface(interface, queue) { _ in }
            self.interface = nil
        }
    }

    /// Reads every waiting frame and answers the guest's requests; runs on `queue`.
    private func readFrames() {
        guard let interface else {
            return
        }
        var buffer = [UInt8](repeating: 0, count: maxPacketSize)
        while true {
            let frame: [UInt8]? = buffer.withUnsafeMutableBytes { bytes in
                var vector = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var packet = vmpktdesc(vm_pkt_size: bytes.count, vm_pkt_iov: vectorPointer, vm_pkt_iovcnt: 1, vm_flags: 0)
                    var count: Int32 = 1
                    guard vmnet_read(interface, &packet, &count) == .VMNET_SUCCESS, count == 1 else {
                        return nil
                    }
                    return Array(bytes.prefix(packet.vm_pkt_size))
                }
            }
            guard let frame else {
                return
            }
            guard let answer = Self.respond(to: frame, lease: lease, serverMAC: serverMAC) else {
                continue
            }
            write(answer.reply, on: interface)
            onReply(answer.request, answer.replyKind)
        }
    }

    /// The kind of the request in `frame`, the kind of its reply and the reply frame, or nil when
    /// the frame is no client message or comes from another client than the lease's.
    static func respond(to frame: [UInt8], lease: DHCPMessage.Lease, serverMAC: [UInt8]) -> (
        request: DHCPMessage.Kind, replyKind: DHCPMessage.Kind, reply: [UInt8]
    )? {
        guard let request = DHCPMessage.parse(frame),
            let reply = DHCPMessage.reply(to: request, lease: lease, serverMAC: serverMAC)
        else {
            return nil
        }
        return (request.kind, reply.kind, reply.frame)
    }

    /// The interface's MAC address and maximum packet size from the start callback's parameters:
    /// an address that is absent gives a nil `mac`, one that does not parse gives an empty one, and
    /// a size of zero keeps `defaultPacketSize`.
    static func interfaceSettings(macAddress: String?, maxPacketSize: UInt64, defaultPacketSize: Int) -> (mac: [UInt8]?, packetSize: Int) {
        (macAddress.map { DHCPMessage.mac($0) ?? [] }, maxPacketSize > 0 ? Int(maxPacketSize) : defaultPacketSize)
    }

    private func write(_ frame: [UInt8], on interface: interface_ref) {
        var frame = frame
        frame.withUnsafeMutableBytes { bytes in
            var vector = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
            withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var packet = vmpktdesc(vm_pkt_size: bytes.count, vm_pkt_iov: vectorPointer, vm_pkt_iovcnt: 1, vm_flags: 0)
                var count: Int32 = 1
                _ = vmnet_write(interface, &packet, &count)
            }
        }
    }
}
