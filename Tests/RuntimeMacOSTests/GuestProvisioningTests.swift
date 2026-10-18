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
