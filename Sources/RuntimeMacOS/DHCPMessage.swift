// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The DHCP exchange of one guest, as Ethernet frames on a vmnet network.
///
/// A vmnet network of apple/container runs no DHCP server. The runtime answers the DISCOVER and
/// REQUEST of its own guest, matched by MAC address, with the address the network allocated.
/// Replies go out as broadcasts, and the lease never expires, so the guest never renews by unicast
/// to the server identifier, which is the network's gateway.
public enum DHCPMessage {
    /// The guest's settings that a reply carries.
    public struct Lease: Sendable, Equatable {
        public var clientMAC: [UInt8]
        public var address: [UInt8]
        public var subnetMask: [UInt8]
        public var gateway: [UInt8]
        public var nameservers: [[UInt8]]

        public init(clientMAC: [UInt8], address: [UInt8], subnetMask: [UInt8], gateway: [UInt8], nameservers: [[UInt8]]) {
            self.clientMAC = clientMAC
            self.address = address
            self.subnetMask = subnetMask
            self.gateway = gateway
            self.nameservers = nameservers
        }
    }

    public enum Kind: UInt8, Sendable {
        case discover = 1
        case offer = 2
        case request = 3
        case decline = 4
        case ack = 5
        case nak = 6
        case release = 7
        case inform = 8
    }

    /// A client message from a frame: its kind, transaction ID, client MAC address, flags and
    /// requested address.
    public struct Request: Sendable, Equatable {
        public var kind: Kind
        public var transactionID: [UInt8]
        public var clientMAC: [UInt8]
        public var flags: [UInt8]
        public var requestedAddress: [UInt8]?
        public var clientAddress: [UInt8]
    }

    static let magicCookie: [UInt8] = [99, 130, 83, 99]
    static let bootpOffset = 14 + 20 + 8
    static let optionsOffset = bootpOffset + 236 + 4

    /// The client message in `frame`, or nil when the frame is no DHCP client message over IPv4.
    public static func parse(_ frame: [UInt8]) -> Request? {
        guard frame.count >= optionsOffset, frame[12] == 0x08, frame[13] == 0x00 else {
            return nil
        }
        let ipHeaderLength = Int(frame[14] & 0x0f) * 4
        guard frame[14] >> 4 == 4, ipHeaderLength == 20, frame[23] == 17 else {
            return nil
        }
        let udp = 14 + ipHeaderLength
        guard frame[udp + 2] == 0, frame[udp + 3] == 67 else {
            return nil
        }
        let bootp = udp + 8
        guard frame[bootp] == 1, frame[bootp + 1] == 1, frame[bootp + 2] == 6,
            Array(frame[bootp + 236..<bootp + 240]) == magicCookie
        else {
            return nil
        }
        var kind: Kind?
        var requested: [UInt8]?
        var index = bootp + 240
        while index < frame.count {
            let code = frame[index]
            if code == 255 {
                break
            }
            if code == 0 {
                index += 1
                continue
            }
            guard index + 1 < frame.count else {
                break
            }
            let length = Int(frame[index + 1])
            let value = index + 2
            guard value + length <= frame.count else {
                break
            }
            switch code {
            case 53 where length == 1:
                kind = Kind(rawValue: frame[value])
            case 50 where length == 4:
                requested = Array(frame[value..<value + 4])
            default:
                break
            }
            index = value + length
        }
        guard let kind else {
            return nil
        }
        return Request(
            kind: kind,
            transactionID: Array(frame[bootp + 4..<bootp + 8]),
            clientMAC: Array(frame[bootp + 28..<bootp + 34]),
            flags: Array(frame[bootp + 10..<bootp + 12]),
            requestedAddress: requested,
            clientAddress: Array(frame[bootp + 12..<bootp + 16])
        )
    }

    /// The kind and frame of the reply to `request` for `lease`, sent from `serverMAC`, or nil
    /// when the request is not from the lease's client or needs no reply.
    public static func reply(to request: Request, lease: Lease, serverMAC: [UInt8]) -> (kind: Kind, frame: [UInt8])? {
        guard request.clientMAC == lease.clientMAC else {
            return nil
        }
        let kind: Kind
        switch request.kind {
        case .discover:
            kind = .offer
        case .request:
            let asked = request.requestedAddress ?? request.clientAddress
            kind = asked == lease.address ? .ack : .nak
        case .inform:
            kind = .ack
        default:
            return nil
        }

        var bootp = [UInt8](repeating: 0, count: 236)
        bootp[0] = 2
        bootp[1] = 1
        bootp[2] = 6
        bootp.replaceSubrange(4..<8, with: request.transactionID)
        bootp.replaceSubrange(10..<12, with: request.flags)
        if kind != .nak {
            bootp.replaceSubrange(16..<20, with: lease.address)
        }
        bootp.replaceSubrange(20..<24, with: lease.gateway)
        bootp.replaceSubrange(28..<34, with: lease.clientMAC)

        var options = magicCookie
        options += [53, 1, kind.rawValue]
        options += [54, 4] + lease.gateway
        if kind != .nak {
            options += [51, 4, 0xff, 0xff, 0xff, 0xff]
            options += [1, 4] + lease.subnetMask
            options += [3, 4] + lease.gateway
            if !lease.nameservers.isEmpty {
                options += [6, UInt8(lease.nameservers.count * 4)] + lease.nameservers.flatMap { $0 }
            }
        }
        options.append(255)

        let payload = bootp + options
        let udpLength = 8 + payload.count
        var udp: [UInt8] = [0, 67, 0, 68, UInt8(udpLength >> 8), UInt8(udpLength & 0xff), 0, 0]
        udp += payload

        let totalLength = 20 + udp.count
        var ip: [UInt8] = [
            0x45, 0, UInt8(totalLength >> 8), UInt8(totalLength & 0xff),
            0, 0, 0, 0,
            64, 17, 0, 0,
        ]
        ip += lease.gateway
        ip += [255, 255, 255, 255]
        let checksum = ipChecksum(ip)
        ip[10] = UInt8(checksum >> 8)
        ip[11] = UInt8(checksum & 0xff)

        return (kind, [UInt8](repeating: 0xff, count: 6) + serverMAC + [0x08, 0x00] + ip + udp)
    }

    /// The Internet checksum of an IPv4 header.
    static func ipChecksum(_ header: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: header.count, by: 2) {
            sum += UInt32(header[index]) << 8 | UInt32(index + 1 < header.count ? header[index + 1] : 0)
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(sum)
    }

    /// The bytes of a dotted IPv4 address, or nil.
    public static func ipv4(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }

    /// The bytes of a MAC address written with colons, or nil.
    public static func mac(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return parts.count == 6 ? parts : nil
    }

    /// The subnet mask of a prefix length.
    public static func mask(prefixLength: Int) -> [UInt8] {
        (0..<4).map { octet in
            let bits = max(0, min(8, prefixLength - octet * 8))
            return bits == 0 ? 0 : UInt8(256 - (1 << (8 - bits)))
        }
    }
}
