// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Foundation
import Testing
import vmnet

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
        let options = try GuestProvisioning(fullName: "CI", username: "ci", password: "correct-horse-battery").startOptions()
        #expect(options.guestProvisioningOptions?.username == "ci")
        #expect(options.guestProvisioningOptions?.logsInAutomatically == true)
        #expect(options.guestProvisioningOptions?.enablesRemoteLogin == true)
    }

    @Test
    func testAnEmptyPasswordIsRejectedBeforeBoot() {
        #expect(throws: (any Error).self) {
            try GuestProvisioning(fullName: "CI", username: "ci", password: "").startOptions()
        }
    }

    @Test
    func testAnInvalidUsernameIsRejectedBeforeBoot() {
        #expect(throws: (any Error).self) {
            try GuestProvisioning(fullName: "CI", username: "not a user name", password: "correct-horse-battery").startOptions()
        }
    }
}

@Suite(.tags(.keychain), .enabled(if: HostRequirement.loginKeychainUsable))
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
        let credentials = GuestCredentials(service: "container-runtime-macos.test.\(UUID().uuidString)", access: .anyApplication)
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
        let credentials = GuestCredentials(service: service, access: .anyApplication)
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

    @Test
    func testClassifyMapsKeychainStatuses() {
        let service = "svc"
        #expect(GuestCredentials.classify(status: 1, errorOutput: "User interaction is not allowed.", service: service) == .keychainLocked(service: service))
        #expect(GuestCredentials.classify(status: -25308, errorOutput: "", service: service) == .keychainLocked(service: service))
        #expect(GuestCredentials.classify(status: -25293, errorOutput: "", service: service) == .keychainRefused(service: service, status: -25293))
        #expect(GuestCredentials.classify(status: 1, errorOutput: "access denied", service: service) == .keychainRefused(service: service, status: 1))
        #expect(GuestCredentials.classify(status: 44, errorOutput: "could not be found", service: service) == nil)
        #expect(GuestCredentials.classify(status: 0, errorOutput: "", service: service) == nil)
        #expect(GuestCredentials.classify(status: 7, errorOutput: "something else", service: service) == nil)
    }

    @Test
    func testClassifyMapsTheRemainingRows() {
        let service = "svc"
        #expect(GuestCredentials.classify(status: -128, errorOutput: "", service: service) == .keychainRefused(service: service, status: -128))
        #expect(GuestCredentials.classify(status: 1, errorOutput: "error -128", service: service) == .keychainRefused(service: service, status: 1))
        #expect(GuestCredentials.classify(status: 1, errorOutput: "error -25293", service: service) == .keychainRefused(service: service, status: 1))
        #expect(GuestCredentials.classify(status: 1, errorOutput: "Authorization failed", service: service) == .keychainRefused(service: service, status: 1))
        #expect(GuestCredentials.classify(status: 1, errorOutput: "error -25308", service: service) == .keychainLocked(service: service))
        #expect(GuestCredentials.classify(status: 1, errorOutput: "USER INTERACTION IS NOT ALLOWED", service: service) == .keychainLocked(service: service))
        #expect(GuestCredentials.classify(status: 44, errorOutput: "User interaction is not allowed.", service: service) == nil)
        #expect(GuestCredentials.classify(status: 0, errorOutput: "denied", service: service) == nil)
    }

    @Test
    func testSecurityArgumentsAreCheckedAndQuoted() throws {
        for hostile in ["a\nb", "a\u{0}b", "x PARBAKE_y", "a\rb", "a\u{7F}b"] {
            #expect(throws: (any Error).self) { try GuestCredentials.security(["find-generic-password", "-s", hostile]) }
        }
        #expect(GuestCredentials.quoted(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(GuestCredentials.quoted("it's $(id)") == "\"it's $(id)\"")
    }

    @Test
    func testPreflightNeverCreatesTheProbeAccount() throws {
        let credentials = GuestCredentials(service: "container-runtime-macos.test.\(UUID().uuidString)", access: .anyApplication)
        try credentials.preflight()
        try credentials.preflight()
        #expect(try credentials.password(for: GuestCredentials.preflightAccount) == nil)
    }

    @Test
    func testAccessFollowsTheSigningIdentity() {
        #expect(KeychainAccess.for(.adHoc) == .anyApplication)
        #expect(KeychainAccess.for(.team("ABCDE12345")) == .creatorOnly)
    }

    @Test
    func testTheWarningNamesTheScopeAndTheRemedy() {
        #expect(GuestCredentials.adHocWarning.contains("every application of this user"))
        #expect(GuestCredentials.adHocWarning.contains("sign parbake with a team identity"))
        #expect(!GuestCredentials.adHocWarning.contains("docs/"))
    }

    @Test
    func testTheTestBinaryIsAdHocSigned() {
        #expect(SigningIdentity.ofCurrentProcess() == .adHoc)
    }

    @Test
    func testPreflightSucceedsOnAnUnlockedKeychain() throws {
        try GuestCredentials(service: "container-runtime-macos.test.\(UUID().uuidString)", access: .anyApplication).preflight()
    }

    @Test
    func testAServiceWithANewlineIsRefusedBeforeSecurityRuns() {
        let credentials = GuestCredentials(service: "bad\nservice", access: .anyApplication)
        #expect(throws: (any Error).self) { try credentials.password(for: "ci") }
        #expect(throws: (any Error).self) { try credentials.store("secret-value", for: "ci") }
        #expect(throws: (any Error).self) { try credentials.remove(for: "ci") }
    }

    @Test(.enabled(if: SigningIdentity.ofCurrentProcess() != .adHoc))
    func testACreatorOnlyRoundTrip() throws {
        let credentials = GuestCredentials(service: "container-runtime-macos.test.\(UUID().uuidString)", access: .creatorOnly)
        defer { try? credentials.remove(for: "ci") }
        try credentials.preflight()
        #expect(try credentials.password(for: "ci") == nil)
        try credentials.store("first-value", for: "ci")
        #expect(try credentials.password(for: "ci") == "first-value")
        try credentials.store("second-value", for: "ci")
        #expect(try credentials.password(for: "ci") == "second-value")
        try credentials.remove(for: "ci")
        #expect(try credentials.password(for: "ci") == nil)
    }
}

struct GuestPreparationTests {
    private let script: String

    init() throws {
        script = try GuestPreparation.script(
            username: "ci", password: "pa$$ 'word\\x", publicKeys: ["ssh-ed25519 AAAA one", "ssh-ed25519 BBBB two"], tidy: true)
    }

    @Test
    func testHostileInputIsRefused() {
        #expect(throws: (any Error).self) {
            try GuestPreparation.script(username: "ci", password: "x\nPARBAKE_PASSWORD\ny", publicKeys: ["k"], tidy: false)
        }
        #expect(throws: (any Error).self) {
            try GuestPreparation.script(username: "ci", password: "x", publicKeys: ["ssh-ed25519 AAAA\nPARBAKE_KEYS"], tidy: false)
        }
        #expect(throws: (any Error).self) {
            try GuestPreparation.script(username: "a'b", password: "x", publicKeys: ["k"], tidy: false)
        }
        #expect(throws: (any Error).self) { try GuestAgentInstallation.script(password: "x\nPARBAKE_ROOT") }
    }

    @Test
    func testHostileSudoCommandsAreRefusedByTheBuilder() {
        for command in ["ALL", "/bin/sh -c x", "/usr/bin/*", "/a'b", "/a\nPARBAKE_ROOT", "/a,b", "relative/path", ""] {
            #expect(throws: (any Error).self) {
                try GuestPreparation.script(username: "ci", password: "x", publicKeys: ["k"], tidy: false, sudoCommands: [command])
            }
        }
        #expect(throws: (any Error).self) {
            try GuestPreparation.script(username: "ci", password: "x", publicKeys: ["k"], tidy: false, sudoCommands: ["/usr/bin/ok", "/a b"])
        }
    }

    @Test
    func testSudoCommandsFollowTheRule() throws {
        try GuestPreparation.checkSudoCommand("/usr/sbin/softwareupdate")
        for command in ["ALL", "/bin/sh -c x", "/usr/bin/*", "/x#y", "/a=b", "/a:b", "/a,b", "/a'b"] {
            #expect(throws: (any Error).self) { try GuestPreparation.checkSudoCommand(command) }
        }
    }

    @Test
    func testPasswordReachesSudoVerbatimWithoutExpansion() throws {
        let password = "p'$(touch MARKER)`touch MARKER`$(id)\\x"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-sudo-\(UUID().uuidString)")
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("marker").path
        let log = directory.appendingPathComponent("sudo.log").path
        let shim = bin.appendingPathComponent("sudo")
        try "#!/bin/sh\ncat >> \"$PARBAKE_TEST_SUDO_LOG\"\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        let built = try GuestPreparation.script(
            username: "ci", password: password.replacingOccurrences(of: "MARKER", with: marker), publicKeys: ["ssh-ed25519 AAAA one"], tidy: false)
        let scriptFile = directory.appendingPathComponent("script.sh")
        try built.write(to: scriptFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptFile.path]
        process.environment = [
            "HOME": directory.path, "PATH": "\(bin.path):/usr/bin:/bin", "PARBAKE_TEST_SUDO_LOG": log,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let received = try String(contentsOfFile: log, encoding: .utf8)
        #expect(received == password.replacingOccurrences(of: "MARKER", with: marker) + "\n")
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

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
    func testTheShutdownComesLastAndTidyIsOptional() throws {
        let lines = script.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.last == "sudo -n /sbin/shutdown -h now >/dev/null")
        #expect(script.contains("NOPASSWD: %s"))
        #expect(script.contains("'/sbin/shutdown'"))
        #expect(script.contains("mdutil -a -i off"))
        let plain = try GuestPreparation.script(username: "ci", password: "x", publicKeys: ["k"], tidy: false)
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

struct GuestSecurityRunnerTests {
    private func stub(_ body: String) throws -> (directory: URL, tool: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("security-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tool = directory.appendingPathComponent("security")
        try Data(body.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        return (directory, tool.path)
    }

    @Test
    func testTheStatusAndStandardErrorReachTheCaller() throws {
        let (directory, tool) = try stub("#!/bin/sh\ncat > /dev/null\necho 'user interaction is not allowed' >&2\nexit 36\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try GuestCredentials.security(["find-generic-password", "-s", "svc"], securityPath: tool)
        #expect(result.status == 36)
        #expect(result.output == "")
        #expect(result.errorOutput == "user interaction is not allowed\n")
    }

    @Test
    func testTheCommandReachesTheToolOnStandardInputAndItsOutputIsReturned() throws {
        let (directory, tool) = try stub("#!/bin/sh\ncat\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try GuestCredentials.security(["add-generic-password", "-w", "se\"cret"], securityPath: tool)
        #expect(result.status == 0)
        #expect(result.output == "\"add-generic-password\" \"-w\" \"se\\\"cret\"\n")
        #expect(result.errorOutput == "")
    }
}

/// The code and printed text of the errors the guest I/O files throw, whatever type carries them.
struct GuestIOErrorTextTests {
    private struct Cause: Error, CustomStringConvertible {
        let description = "boom"
    }

    private static func observe(_ body: () async throws -> Void) async -> (code: ContainerizationError.Code, text: String)? {
        do {
            try await body()
            return nil
        } catch {
            guard let mapped = RuntimeLifecycle.containerizationError(from: error) as? ContainerizationError else {
                return nil
            }
            return (mapped.code, mapped.localizedDescription)
        }
    }

    private static func expect(
        _ body: () async throws -> Void, code: ContainerizationError.Code, text: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let seen = await observe(body)
        #expect(seen?.code == code, sourceLocation: sourceLocation)
        #expect(seen?.text == text, sourceLocation: sourceLocation)
    }

    @Test
    func aKeychainStatusFailureNamesTheAction() {
        let error = GuestCredentials.failure(status: 12, service: "svc", "probe the keychain")
        let mapped = RuntimeLifecycle.containerizationError(from: error) as? ContainerizationError
        #expect(mapped?.code == .internalError)
        #expect(mapped?.localizedDescription == "failed to probe the keychain: keychain status 12")
    }

    @Test
    func aSecurityFailureNamesTheReason() {
        let withReason = GuestCredentials.SecurityResult(status: 3, output: "", errorOutput: "boom\n")
        let without = GuestCredentials.SecurityResult(status: 3, output: "", errorOutput: " \n")
        let first = RuntimeLifecycle.containerizationError(from: GuestCredentials.error(withReason, "probe the keychain")) as? ContainerizationError
        let second = RuntimeLifecycle.containerizationError(from: GuestCredentials.error(without, "probe the keychain")) as? ContainerizationError
        #expect(first?.code == .internalError)
        #expect(first?.localizedDescription == "failed to probe the keychain: boom")
        #expect(second?.code == .internalError)
        #expect(second?.localizedDescription == "failed to probe the keychain: exit status 3")
    }

    @Test
    func aPasswordWithANewlineIsRefused() async {
        await Self.expect(
            { try GuestCredentials(service: "svc", access: .anyApplication).store("a\nb", for: "user") },
            code: .invalidArgument, text: "a keychain password cannot contain a newline")
    }

    @Test
    func aSudoCommandThatIsNoPathIsRefused() async {
        await Self.expect(
            { try GuestPreparation.checkSudoCommand("rm -rf") }, code: .invalidArgument,
            text:
                "sudo command rm -rf must be an absolute command path with no arguments or wildcards, using only the characters A-Z a-z 0-9 . _ / + -"
        )
    }

    @Test
    func anUnsafeUsernameIsRefused() async {
        await Self.expect(
            { _ = try GuestPreparation.script(username: "Bad Name", password: "pw", publicKeys: [], tidy: false) },
            code: .invalidArgument,
            text: "username Bad Name must be 1 to 31 characters: a lowercase letter or _ first, then a-z, 0-9, _ or -")
    }

    @Test
    func aRestoreImageValueWithoutAFileNameIsRefused() async {
        await Self.expect(
            { _ = try RestoreImageSource("https://") }, code: .invalidArgument, text: "https:// is no restore image URL")
    }

    @Test
    func aDownloadThatDoesNotLoadIsDeletedAndNamesItsCause() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = RestoreImageCache(directory: directory)
        let url = try #require(URL(string: "https://mirror.example/Image.ipsw"))
        let file = cache.file(for: url)
        await Self.expect(
            {
                _ = try await cache.fetch(url, download: { _, destination in try Data("x".utf8).write(to: destination) }, verify: { _ in throw Cause() })
            },
            code: .invalidState,
            text: "\(file.path) is no restore image Virtualization.framework can load; it was deleted, run create again (cause: \"boom\")")
    }

    @Test
    func aFailedCurlNamesTheStatus() async throws {
        let url = try #require(URL(string: "https://example.invalid/image.ipsw"))
        await Self.expect(
            { try await RestoreImageCache.curl(url, to: URL(fileURLWithPath: "/tmp/never"), executable: URL(fileURLWithPath: "/usr/bin/false")) },
            code: .internalError,
            text: "downloading https://example.invalid/image.ipsw failed (curl exit status 1); run create again to resume")
    }

    @Test
    func anExistingBundleIsNotReplacedByDefault() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-exists-\(UUID())")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        await Self.expect(
            { try await BundleReplacement.build(at: target, replacing: false) { _ in } }, code: .exists,
            text: "\(target.path) already exists; pass --replace to rebuild it")
    }

    @Test
    func theDHCPInterfaceFailuresNameTheStatus() {
        let start = RuntimeLifecycle.containerizationError(from: GuestDHCPServer.startFailure(.VMNET_FAILURE)) as? ContainerizationError
        let watch = RuntimeLifecycle.containerizationError(from: GuestDHCPServer.watchFailure(.VMNET_FAILURE)) as? ContainerizationError
        #expect(start?.code == .internalError)
        #expect(start?.localizedDescription == "failed to start the DHCP interface on the vmnet network, status 1001")
        #expect(watch?.code == .internalError)
        #expect(watch?.localizedDescription == "failed to watch the DHCP interface, status 1001")
    }
}
