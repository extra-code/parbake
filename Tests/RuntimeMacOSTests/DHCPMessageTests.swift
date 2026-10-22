// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RuntimeMacOS

/// Malformed client frames: `DHCPMessage.parse` returns nil for each and never traps.
struct DHCPParserMutationTests {
    private static let guest: [UInt8] = [0xfe, 0x28, 0x22, 0x08, 0x0e, 0x4d]
    private static let discoverOptions: [UInt8] = [53, 1, 1, 55, 3, 1, 3, 6, 255]

    /// A client frame as macOS sends it, with `options` after the magic cookie.
    private static func frame(options: [UInt8] = discoverOptions) -> [UInt8] {
        var bootp = [UInt8](repeating: 0, count: 236)
        bootp[0] = 1
        bootp[1] = 1
        bootp[2] = 6
        bootp.replaceSubrange(4..<8, with: [0xde, 0xad, 0xbe, 0xef])
        bootp.replaceSubrange(28..<34, with: guest)
        let payload = bootp + DHCPMessage.magicCookie + options
        let udpLength = 8 + payload.count
        let udp: [UInt8] = [0, 68, 0, 67, UInt8(udpLength >> 8), UInt8(udpLength & 0xff), 0, 0] + payload
        let ipLength = 20 + udp.count
        let ip: [UInt8] = [
            0x45, 0, UInt8(ipLength >> 8), UInt8(ipLength & 0xff), 0, 0, 0, 0, 64, 17, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255,
        ]
        return [UInt8](repeating: 0xff, count: 6) + guest + [0x08, 0x00] + ip + udp
    }

    private static func mutated(_ change: (inout [UInt8]) -> Void) -> [UInt8] {
        var frame = frame()
        change(&frame)
        return frame
    }

    private static let bootp = DHCPMessage.bootpOffset

    /// Each case is a labelled malformed frame.
    private static let malformed: [(label: String, frame: [UInt8])] = {
        var cases: [(String, [UInt8])] = []
        let valid = frame()
        for length in 0..<(DHCPMessage.optionsOffset + 3) {
            cases.append(("truncated at \(length)", Array(valid.prefix(length))))
        }
        cases.append(("corrupt cookie", mutated { $0[bootp + 236] = 0 }))
        cases.append(("op = 2", mutated { $0[bootp] = 2 }))
        cases.append(("htype = 6", mutated { $0[bootp + 1] = 6 }))
        cases.append(("hlen = 0", mutated { $0[bootp + 2] = 0 }))
        cases.append(("IHL = 6", mutated { $0[14] = 0x46 }))
        cases.append(("option 53 length 0", frame(options: [53, 0, 1, 255])))
        cases.append(("option 53 length 2", frame(options: [53, 2, 1, 1, 255])))
        cases.append(("option length past the frame", frame(options: [60, 200, 1, 2, 3])))
        cases.append(("option code without length", frame(options: [60])))
        cases.append(("end marker without option 53", frame(options: [255])))
        cases.append(("unknown option 53 value 0", frame(options: [53, 1, 0, 255])))
        cases.append(("unknown option 53 value 9", frame(options: [53, 1, 9, 255])))
        cases.append(("unknown option 53 value 99", frame(options: [53, 1, 99, 255])))
        cases.append(("no end marker, no option 53", frame(options: [55, 3, 1, 3, 6])))
        return cases
    }()

    @Test(arguments: malformed)
    func malformedFrameIsRefused(_ item: (label: String, frame: [UInt8])) {
        #expect(DHCPMessage.parse(item.frame) == nil, "\(item.label)")
    }

    @Test
    func missingEndMarkerAfterOption53KeepsTheParsedKind() throws {
        let request = try #require(DHCPMessage.parse(Self.frame(options: [53, 1, 1])))
        #expect(request.kind == .discover)
        #expect(request.clientMAC == Self.guest)
        #expect(request.transactionID == [0xde, 0xad, 0xbe, 0xef])
    }

    @Test
    func validDiscoverIsParsed() throws {
        let request = try #require(DHCPMessage.parse(Self.frame()))
        #expect(request.kind == .discover)
    }

    @Test
    func anOversizedFrameIsParsedWithoutTrapping() throws {
        let big = Self.frame() + [UInt8](repeating: 0xaa, count: 70_000)
        #expect(try #require(DHCPMessage.parse(big)).kind == .discover)
        let longOption = Self.frame(options: [60, 255] + [UInt8](repeating: 0x41, count: 255) + [53, 1, 1, 255])
        #expect(try #require(DHCPMessage.parse(longOption)).kind == .discover)
    }

    @Test
    func aZeroLengthOptionIsSkipped() throws {
        let request = try #require(DHCPMessage.parse(Self.frame(options: [60, 0, 53, 1, 1, 255])))
        #expect(request.kind == .discover)
    }

    @Test
    func padBytesBeforeOption53AreSkipped() throws {
        let request = try #require(DHCPMessage.parse(Self.frame(options: [0, 0, 0, 53, 1, 3, 255])))
        #expect(request.kind == .request)
    }

    @Test
    func option50WithALengthOtherThanFourIsIgnored() throws {
        for length: UInt8 in [0, 3, 5] {
            let value = [UInt8](repeating: 9, count: Int(length))
            let request = try #require(DHCPMessage.parse(Self.frame(options: [53, 1, 3, 50, length] + value + [255])))
            #expect(request.kind == .request)
            #expect(request.requestedAddress == nil, "length \(length)")
        }
        let valid = try #require(DHCPMessage.parse(Self.frame(options: [53, 1, 3, 50, 4, 10, 0, 0, 2, 255])))
        #expect(valid.requestedAddress == [10, 0, 0, 2])
    }
}
