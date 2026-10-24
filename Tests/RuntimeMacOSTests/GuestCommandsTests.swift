// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RuntimeMacOS

struct GuestCommandsTests {
    @Test
    func testShutdownIsThePasswordlessSudoCommand() {
        #expect(GuestCommands.shutdown == "sudo -n /sbin/shutdown -h now")
        #expect(GuestCommands.shutdownDiscardingOutput == "sudo -n /sbin/shutdown -h now >/dev/null")
    }

    @Test
    func testShutdownIfAllowedChecksTheRuleBeforeItAnnounces() {
        #expect(GuestCommands.acceptedMarker == "parbake: shutting down")
        #expect(
            GuestCommands.shutdownIfAllowed
                == "sudo -n -l /sbin/shutdown >/dev/null && echo 'parbake: shutting down' && sudo -n /sbin/shutdown -h now >/dev/null")
    }

    @Test
    func testShutdownArgumentsDependOnWhoRunsThem() {
        #expect(GuestCommands.shutdownArguments(asRoot: true) == ["/sbin/shutdown", "-h", "now"])
        #expect(GuestCommands.shutdownArguments(asRoot: false) == ["/usr/bin/sudo", "-n", "/sbin/shutdown", "-h", "now"])
    }

    @Test
    func testAsRootFragmentFeedsThePasswordToSudo() {
        #expect(GuestCommands.asRoot == "printf '%s\\n' \"$PARBAKE_PASSWORD\" | sudo -S -p '' /bin/sh -c \"$PARBAKE_ROOT\"")
    }
}
