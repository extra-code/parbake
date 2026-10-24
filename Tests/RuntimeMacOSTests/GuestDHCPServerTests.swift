// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RuntimeMacOS

/// The server's frame handling and its start-callback parse, without a vmnet interface.
struct GuestDHCPServerTests {
    private static let guest: [UInt8] = [0xfe, 0x28, 0x22, 0x08, 0x0e, 0x4d]
    private static let server: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]
    private static let lease = DHCPMessage.Lease(
        clientMAC: guest, address: [192, 168, 64, 2], subnetMask: [255, 255, 255, 0], gateway: [192, 168, 64, 1], nameservers: [[192, 168, 64, 1]])

    /// A client frame from `mac` with `options` after the magic cookie.
    private static func frame(mac: [UInt8] = guest, options: [UInt8]) -> [UInt8] {
        var bootp = [UInt8](repeating: 0, count: 236)
        bootp[0] = 1
        bootp[1] = 1
        bootp[2] = 6
        bootp.replaceSubrange(4..<8, with: [0xde, 0xad, 0xbe, 0xef])
        bootp.replaceSubrange(28..<34, with: mac)
        let payload = bootp + DHCPMessage.magicCookie + options
        let udpLength = 8 + payload.count
        let udp: [UInt8] = [0, 68, 0, 67, UInt8(udpLength >> 8), UInt8(udpLength & 0xff), 0, 0] + payload
        let ipLength = 20 + udp.count
        let ip: [UInt8] = [
            0x45, 0, UInt8(ipLength >> 8), UInt8(ipLength & 0xff), 0, 0, 0, 0, 64, 17, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255,
        ]
        return [UInt8](repeating: 0xff, count: 6) + mac + [0x08, 0x00] + ip + udp
    }

    @Test
    func aDiscoverIsOffered() throws {
        let answer = try #require(Self.respond(Self.frame(options: [53, 1, 1, 255])))
        #expect(answer.request == .discover)
        #expect(answer.replyKind == .offer)
        #expect(answer.reply.starts(with: [UInt8](repeating: 0xff, count: 6) + Self.server + [0x08, 0x00]))
        #expect(answer.reply.suffix(from: DHCPMessage.bootpOffset + 16).starts(with: Self.lease.address))
    }

    @Test
    func aRequestForTheLeasedAddressIsAcknowledged() throws {
        let answer = try #require(Self.respond(Self.frame(options: [53, 1, 3, 50, 4, 192, 168, 64, 2, 255])))
        #expect(answer.request == .request)
        #expect(answer.replyKind == .ack)
    }

    @Test
    func aForeignClientGetsNoReply() {
        let foreign = Self.frame(mac: [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff], options: [53, 1, 1, 255])
        #expect(Self.respond(foreign) == nil)
    }

    @Test
    func aMalformedFrameGetsNoReply() {
        #expect(Self.respond([]) == nil)
        #expect(Self.respond(Array(Self.frame(options: [53, 1, 1, 255]).prefix(40))) == nil)
        #expect(Self.respond(Self.frame(options: [255])) == nil)
    }

    @Test
    func startParametersCarryTheMACAndPacketSize() {
        let settings = GuestDHCPServer.interfaceSettings(macAddress: "fe:28:22:08:0e:4d", maxPacketSize: 1600, defaultPacketSize: 1518)
        #expect(settings.mac == Self.guest)
        #expect(settings.packetSize == 1600)
    }

    @Test
    func startParametersFallBackToTheDefaults() {
        let missing = GuestDHCPServer.interfaceSettings(macAddress: nil, maxPacketSize: 0, defaultPacketSize: 1518)
        #expect(missing.mac == nil)
        #expect(missing.packetSize == 1518)
        #expect(GuestDHCPServer.interfaceSettings(macAddress: "nonsense", maxPacketSize: 0, defaultPacketSize: 1518).mac == [])
    }

    private static func respond(_ frame: [UInt8]) -> (request: DHCPMessage.Kind, replyKind: DHCPMessage.Kind, reply: [UInt8])? {
        GuestDHCPServer.respond(to: frame, lease: lease, serverMAC: server)
    }
}
