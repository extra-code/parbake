// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

@Suite(.serialized)
struct GuestShellTests {
    private func options(_ argv: [String]) -> Set<String> {
        var found: Set<String> = []
        var index = 0
        while index < argv.count - 1 {
            if argv[index] == "-o" { found.insert(argv[index + 1]) }
            index += 1
        }
        return found
    }

    @Test(arguments: [GuestShell.Credential.password("pw"), .key(URL(fileURLWithPath: "/tmp/key"))])
    func testTheArgumentsAreHardenedAndEndWithTheTarget(credential: GuestShell.Credential) throws {
        let argv = try #require(GuestShell.arguments(username: "u", address: "192.168.64.3", credential: credential, command: "cmd"))
        #expect(Array(argv.suffix(5)) == ["-l", "u", "--", "192.168.64.3", "cmd"])
        let joined = argv.joined(separator: " ")
        #expect(joined.contains("-F /dev/null"))
        let set = options(argv)
        for option in [
            "ForwardAgent=no", "ClearAllForwardings=yes", "ControlMaster=no", "ControlPath=none", "IdentityAgent=none", "ServerAliveInterval=5",
            "ServerAliveCountMax=3", "ConnectTimeout=5",
        ] {
            #expect(set.contains(option), "missing \(option)")
        }
    }

    @Test
    func testRefusesAnOptionLikeUsernameOrAddress() {
        let credential = GuestShell.Credential.password("pw")
        #expect(GuestShell.arguments(username: "-oProxyCommand=x", address: "192.168.64.3", credential: credential, command: "c") == nil)
        #expect(GuestShell.arguments(username: "u", address: "-x", credential: credential, command: "c") == nil)
    }

    @Test
    func testRunRefusesAnInvalidTarget() {
        let result = GuestShell(username: "-oProxyCommand=x", credential: .password("pw")).run("c", on: "192.168.64.3")
        #expect(result.status == -1)
        #expect(result.errorOutput == "invalid guest username or address")
        #expect(!result.timedOut)
    }

    private func shell(_ stub: URL, credential: GuestShell.Credential = .password("pw")) -> GuestShell {
        GuestShell(username: "u", credential: credential, sshPath: stub.path)
    }

    @Test
    func testATimeoutKillsTheChild() throws {
        let stub = try Self.makeStub("#!/bin/sh\nexec sleep 30\n")
        defer { try? FileManager.default.removeItem(at: stub) }
        let start = ContinuousClock.now
        let result = shell(stub).run("c", on: "192.168.64.3", timeout: .seconds(1))
        #expect(result.timedOut)
        #expect(result.status == -1)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test
    func testAChildThatIgnoresTermIsKilled() throws {
        let stub = try Self.makeStub("#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n")
        defer { try? FileManager.default.removeItem(at: stub) }
        let start = ContinuousClock.now
        let result = shell(stub).run("c", on: "192.168.64.3", timeout: .milliseconds(500))
        #expect(result.timedOut)
        #expect(result.status == -1)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .seconds(2))
        #expect(elapsed < .seconds(8))
    }

    @Test
    func testAChildThatIgnoresStdinDoesNotCrash() throws {
        let stub = try Self.makeStub("#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: stub) }
        let result = shell(stub).run("c", on: "192.168.64.3", input: Data(repeating: 0x61, count: 1 << 20), timeout: .seconds(10))
        #expect(!result.timedOut)
        #expect(result.status == 0)
    }

    @Test
    func testLargeOutputOnBothStreamsWhileInputIsWritten() throws {
        let stub = try Self.makeStub("#!/bin/sh\ntee /dev/stderr\n")
        defer { try? FileManager.default.removeItem(at: stub) }
        let size = 4 << 20
        let result = shell(stub).run("c", on: "192.168.64.3", input: Data(repeating: 0x62, count: size), timeout: .seconds(30))
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.output.utf8.count == size)
        #expect(result.errorOutput.utf8.count == size)
    }

    @Test
    func testTheChildGetsAMinimalEnvironment() throws {
        let stub = try Self.makeStub("#!/bin/sh\nenv\n")
        defer { try? FileManager.default.removeItem(at: stub) }
        setenv("PARBAKE_TEST_CANARY", "leaked", 1)
        defer { unsetenv("PARBAKE_TEST_CANARY") }
        let keyed = shell(stub, credential: .key(URL(fileURLWithPath: "/tmp/key"))).run("c", on: "192.168.64.3", timeout: .seconds(10))
        let keyedLines = Set(keyed.output.split(separator: "\n").map(String.init))
        #expect(keyedLines.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(keyedLines.contains { $0.hasPrefix("HOME=") })
        #expect(!keyed.output.contains("PARBAKE_TEST_CANARY"))
        #expect(!keyed.output.contains("SSH_ASKPASS"))

        let password = shell(stub).run("c", on: "192.168.64.3", timeout: .seconds(10))
        let lines = Set(password.output.split(separator: "\n").map(String.init))
        #expect(lines.contains("PARBAKE_SSH_PASSWORD=pw"))
        #expect(lines.contains("SSH_ASKPASS_REQUIRE=force"))
        #expect(!password.output.contains("PARBAKE_TEST_CANARY"))
    }

    @Test
    func testTheExitStatusAndStandardInputReachTheCaller() throws {
        let stub = try Self.makeStub("#!/bin/sh\ncat\necho oops >&2\nexit 7\n")
        defer { try? FileManager.default.removeItem(at: stub) }
        let result = shell(stub).run("c", on: "192.168.64.3", input: "echoed", timeout: .seconds(10))
        #expect(result.status == 7)
        #expect(result.output == "echoed")
        #expect(result.errorOutput == "oops\n")
        #expect(!result.timedOut)
    }

    private static func makeStub(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-stub-\(UUID().uuidString)")
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
