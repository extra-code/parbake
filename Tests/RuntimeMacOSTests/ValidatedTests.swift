// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Testing

@testable import RuntimeMacOS

struct ValidatedTests {
    @Test(arguments: ["runner", "_ci", String(repeating: "a", count: 31), "a-b_c9"])
    func testAcceptsUsernames(name: String) {
        #expect(GuestUsername(rawValue: name)?.rawValue == name)
    }

    @Test(arguments: [String(repeating: "a", count: 32), "Runner", "1ci", "ci\n", "ci;id", "-l", ""])
    func testRefusesUsernames(name: String) {
        #expect(GuestUsername(rawValue: name) == nil)
    }

    @Test(arguments: ["/usr/sbin/softwareupdate", "/bin/x+y-z.1_2"])
    func testAcceptsSudoCommands(command: String) {
        #expect(SudoCommand(rawValue: command) != nil)
    }

    @Test(arguments: ["ALL", "/bin/sh -c x", "/usr/bin/*", "/x#y", "/a=b", "/a:b", "", "/", "/a\n"])
    func testRefusesSudoCommands(command: String) {
        #expect(SudoCommand(rawValue: command) == nil)
    }

    @Test(arguments: ["\n", "\r", "\u{0}", "\u{7F}", "a PARBAKE_ROOT b"])
    func testRefusesScriptInput(value: String) {
        #expect(throws: ContainerizationError.self) { try ScriptInput.check(value, field: "password") }
    }

    @Test
    func testScriptInputErrorNamesTheField() {
        do {
            try ScriptInput.check("a\nb", field: "password")
            Issue.record("expected a throw")
        } catch {
            #expect("\(error)".contains("password"))
            #expect((error as? ContainerizationError)?.code == .invalidArgument)
        }
    }

    @Test
    func testAcceptsAPlainPassword() throws {
        try ScriptInput.check("it's $HOME `x` \"q\"", field: "password")
    }

    @Test
    func testAcceptsIPv4() {
        #expect(IPv4Address.isValid("192.168.64.3"))
    }

    @Test(arguments: ["192.168.64.3 ", " 192.168.64.3", "::1", "-oProxyCommand=x", "256.1.1.1", ""])
    func testRefusesIPv4(value: String) {
        #expect(!IPv4Address.isValid(value))
    }
}
