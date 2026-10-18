// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

struct DHCPLeasesTests {
    private let leases = """
        {
        \tname=Mac
        \tip_address=192.168.64.3
        \thw_address=1,5e:a:4:b1:c2:d
        \tidentifier=1,5e:a:4:b1:c2:d
        \tlease=0x6712aa00
        }
        {
        \tname=other
        \tip_address=192.168.64.4
        \thw_address=1,de:ad:be:ef:0:1
        \tidentifier=1,de:ad:be:ef:0:1
        \tlease=0x6712ab00
        }
        {
        \tname=Mac
        \tip_address=192.168.64.7
        \thw_address=1,5e:a:4:b1:c2:d
        \tidentifier=1,5e:a:4:b1:c2:d
        \tlease=0x6712ac00
        }
        """

    @Test
    func testMatchesAMacWrittenWithLeadingZeros() {
        #expect(DHCPLeases.address(for: "de:ad:be:ef:00:01", in: leases) == "192.168.64.4")
    }

    @Test
    func testTakesTheNewestLeaseOfTheMac() {
        #expect(DHCPLeases.address(for: "5E:0A:04:B1:C2:0D", in: leases) == "192.168.64.7")
    }

    @Test
    func testAnUnknownMacHasNoAddress() {
        #expect(DHCPLeases.address(for: "02:00:00:00:00:01", in: leases) == nil)
        #expect(DHCPLeases.address(for: "02:00:00:00:00:01", in: "") == nil)
    }
}

struct LockContentionTests {
    @Test
    func testAWrappedEAGAINIsLockContention() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
        let wrapped = NSError(domain: "VZErrorDomain", code: 2, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(MacOSVirtualMachine.isLockContention(wrapped))
    }

    @Test
    func testOtherErrorsAreNotLockContention() {
        #expect(!MacOSVirtualMachine.isLockContention(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        #expect(!MacOSVirtualMachine.isLockContention(NSError(domain: "VZErrorDomain", code: 2)))
    }
}

struct GuestProvisioningTests {
    @Test
    func testValidSettingsGiveStartOptions() throws {
        guard #available(macOS 27, *) else { return }
        let options = try GuestProvisioning(fullName: "CI", username: "ci", password: "correct-horse-battery").startOptions()
        #expect(options.guestProvisioningOptions?.username == "ci")
        #expect(options.guestProvisioningOptions?.logsInAutomatically == true)
        #expect(options.guestProvisioningOptions?.enablesRemoteLogin == true)
    }

    @Test
    func testAnEmptyPasswordIsRejectedBeforeBoot() {
        guard #available(macOS 27, *) else { return }
        #expect(throws: (any Error).self) {
            try GuestProvisioning(fullName: "CI", username: "ci", password: "").startOptions()
        }
    }

    @Test
    func testAnInvalidUsernameIsRejectedBeforeBoot() {
        guard #available(macOS 27, *) else { return }
        #expect(throws: (any Error).self) {
            try GuestProvisioning(fullName: "CI", username: "not a user name", password: "correct-horse-battery").startOptions()
        }
    }
}

struct GuestCredentialsTests {
    @Test
    func testGeneratedPasswordsUseTheAlphabetAndDiffer() throws {
        let first = try GuestCredentials.generatePassword()
        let second = try GuestCredentials.generatePassword()
        #expect(first.count == 32)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        #expect(first != second)
    }

    @Test
    func testStoresReplacesAndRemovesAPassword() throws {
        let credentials = GuestCredentials(service: "container-runtime-macos.test.\(UUID().uuidString)")
        defer { try? credentials.remove(for: "ci") }
        #expect(try credentials.password(for: "ci") == nil)

        let generated = try credentials.passwordCreatingIfNeeded(for: "ci")
        #expect(try credentials.password(for: "ci") == generated)
        #expect(try credentials.passwordCreatingIfNeeded(for: "ci") == generated)

        try credentials.store("replaced", for: "ci")
        #expect(try credentials.password(for: "ci") == "replaced")

        try credentials.remove(for: "ci")
        #expect(try credentials.password(for: "ci") == nil)
    }

    @Test
    func testTheSecurityToolReadsThePasswordWithoutAPrompt() throws {
        let service = "container-runtime-macos.test.\(UUID().uuidString)"
        let credentials = GuestCredentials(service: service)
        defer { try? credentials.remove(for: "ci") }
        try credentials.store("open-to-every-app", for: "ci")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", "ci", "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        // A keychain prompt would block; the deadline turns it into a failure.
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(output.trimmingCharacters(in: .newlines) == "open-to-every-app")
    }
}

struct GuestPreparationTests {
    private let script = GuestPreparation.script(
        username: "ci", password: "pa$$ 'word\\x", publicKeys: ["ssh-ed25519 AAAA one", "ssh-ed25519 BBBB two"], tidy: true)

    @Test
    func testTheScriptParses() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n"]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test
    func testTheHeredocsCarryKeysAndPasswordVerbatim() {
        let lines = script.components(separatedBy: "\n")
        #expect(lines.contains("ssh-ed25519 AAAA one"))
        #expect(lines.contains("ssh-ed25519 BBBB two"))
        #expect(lines.contains("pa$$ 'word\\x"))
        #expect(lines.contains("PARBAKE_KEYS"))
        #expect(lines.contains("PARBAKE_PASSWORD"))
        #expect(lines.contains("PARBAKE_ROOT"))
    }

    @Test
    func testTheShutdownComesLastAndTidyIsOptional() {
        let lines = script.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.last == "sudo -n /sbin/shutdown -h now >/dev/null")
        #expect(script.contains("NOPASSWD: %s"))
        #expect(script.contains("'/sbin/shutdown'"))
        #expect(script.contains("mdutil -a -i off"))
        let plain = GuestPreparation.script(username: "ci", password: "x", publicKeys: ["k"], tidy: false)
        #expect(!plain.contains("mdutil"))
        #expect(!plain.contains("Caches"))
    }
}

struct DHCPMessageTests {
    private let guest: [UInt8] = [0xfe, 0x28, 0x22, 0x08, 0x0e, 0x4d]
    private let server: [UInt8] = [0x02, 0, 0, 0, 0, 0x01]
    private var lease: DHCPMessage.Lease {
        DHCPMessage.Lease(
            clientMAC: guest, address: [192, 168, 64, 2], subnetMask: [255, 255, 255, 0], gateway: [192, 168, 64, 1],
            nameservers: [[192, 168, 64, 1]])
    }

    /// A client frame as macOS sends it: broadcast from 0.0.0.0:68 to 255.255.255.255:67.
    private func clientFrame(kind: UInt8, mac: [UInt8], requested: [UInt8]? = nil) -> [UInt8] {
        var bootp = [UInt8](repeating: 0, count: 236)
        bootp[0] = 1
        bootp[1] = 1
        bootp[2] = 6
        bootp.replaceSubrange(4..<8, with: [0xde, 0xad, 0xbe, 0xef])
        bootp.replaceSubrange(28..<34, with: mac)
        var options = DHCPMessage.magicCookie + [53, 1, kind]
        if let requested {
            options += [50, 4] + requested
        }
        options += [55, 3, 1, 3, 6, 255]
        let payload = bootp + options
        let udp: [UInt8] = [0, 68, 0, 67, UInt8((8 + payload.count) >> 8), UInt8((8 + payload.count) & 0xff), 0, 0] + payload
        let ip: [UInt8] = [0x45, 0, UInt8((20 + udp.count) >> 8), UInt8((20 + udp.count) & 0xff), 0, 0, 0, 0, 64, 17, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255]
        return [UInt8](repeating: 0xff, count: 6) + mac + [0x08, 0x00] + ip + udp
    }

    private func option(_ code: UInt8, in frame: [UInt8]) -> [UInt8]? {
        var index = DHCPMessage.optionsOffset
        while index + 1 < frame.count, frame[index] != 255 {
            let length = Int(frame[index + 1])
            if frame[index] == code {
                return Array(frame[index + 2..<index + 2 + length])
            }
            index += 2 + length
        }
        return nil
    }

    @Test
    func testADiscoverGetsAnOfferWithTheLease() throws {
        let request = try #require(DHCPMessage.parse(clientFrame(kind: 1, mac: guest)))
        #expect(request.kind == .discover)
        let reply = try #require(DHCPMessage.reply(to: request, lease: lease, serverMAC: server))
        #expect(reply.kind == .offer)
        let frame = reply.frame
        #expect(Array(frame[0..<6]) == [0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        #expect(Array(frame[6..<12]) == server)
        let bootp = DHCPMessage.bootpOffset
        #expect(frame[bootp] == 2)
        #expect(Array(frame[bootp + 4..<bootp + 8]) == [0xde, 0xad, 0xbe, 0xef])
        #expect(Array(frame[bootp + 16..<bootp + 20]) == [192, 168, 64, 2])
        #expect(option(53, in: frame) == [2])
        #expect(option(54, in: frame) == [192, 168, 64, 1])
        #expect(option(51, in: frame) == [0xff, 0xff, 0xff, 0xff])
        #expect(option(1, in: frame) == [255, 255, 255, 0])
        #expect(option(3, in: frame) == [192, 168, 64, 1])
        #expect(option(6, in: frame) == [192, 168, 64, 1])
        #expect(DHCPMessage.ipChecksum(Array(frame[14..<34])) == 0)
    }

    @Test
    func testARequestForTheLeaseIsAckedAndAnyOtherIsNaked() throws {
        let matching = try #require(DHCPMessage.parse(clientFrame(kind: 3, mac: guest, requested: [192, 168, 64, 2])))
        #expect(DHCPMessage.reply(to: matching, lease: lease, serverMAC: server)?.kind == .ack)
        let other = try #require(DHCPMessage.parse(clientFrame(kind: 3, mac: guest, requested: [169, 254, 1, 2])))
        let nak = try #require(DHCPMessage.reply(to: other, lease: lease, serverMAC: server))
        #expect(nak.kind == .nak)
        #expect(option(1, in: nak.frame) == nil)
    }

    @Test
    func testAnotherClientGetsNoReply() throws {
        let request = try #require(DHCPMessage.parse(clientFrame(kind: 1, mac: [2, 0, 0, 0, 0, 9])))
        #expect(DHCPMessage.reply(to: request, lease: lease, serverMAC: server) == nil)
    }

    @Test
    func testFramesOtherThanClientMessagesAreIgnored() {
        var reply = clientFrame(kind: 1, mac: guest)
        reply[14 + 20 + 3] = 68
        #expect(DHCPMessage.parse(reply) == nil)
        var arp = clientFrame(kind: 1, mac: guest)
        arp[12] = 0x08
        arp[13] = 0x06
        #expect(DHCPMessage.parse(arp) == nil)
        #expect(DHCPMessage.parse([1, 2, 3]) == nil)
    }

    @Test
    func testMasksOfPrefixLengths() {
        #expect(DHCPMessage.mask(prefixLength: 24) == [255, 255, 255, 0])
        #expect(DHCPMessage.mask(prefixLength: 18) == [255, 255, 192, 0])
        #expect(DHCPMessage.mask(prefixLength: 30) == [255, 255, 255, 252])
    }
}
