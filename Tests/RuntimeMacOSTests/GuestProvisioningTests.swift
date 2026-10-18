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
