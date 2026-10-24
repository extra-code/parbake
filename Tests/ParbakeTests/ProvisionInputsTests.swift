// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import RuntimeMacOS
import Testing

@testable import parbake

struct ProvisionInputsTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ content: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func validate(
        username: String = "ci", keys: [URL] = [], sudo: [String] = [], agent: String? = nil, noAgent: Bool = true, scripts: [URL] = [],
        keychain: Bool = false, preflight: @escaping (String) throws -> Void = { _ in }
    ) async throws {
        try await ProvisionInputs.validate(
            username: username, authorizedKeys: keys, sudo: sudo, agent: agent, noAgent: noAgent, scripts: scripts, keychain: keychain,
            keychainService: "svc", keychainPreflight: preflight)
    }

    @Test
    func testValidInputsPass() async throws {
        let key = try file("k.pub", "ssh-ed25519 AAAA one\n")
        let script = try file("s.sh", "true\n")
        let agent = try file("agent", "bin")
        try await validate(keys: [key], sudo: ["/usr/sbin/softwareupdate"], agent: agent.path, noAgent: false, scripts: [script])
    }

    @Test(arguments: ["Runner", "ci;id", "-l", "", "ci\n"])
    func testRefusesABadUsername(name: String) async {
        await #expect(throws: ValidationError.self) { try await validate(username: name) }
    }

    @Test
    func testAnInvalidUsernameNamesTheRule() async {
        do {
            try await validate(username: "Runner")
            Issue.record("expected a throw")
        } catch {
            #expect("\(error)".contains(GuestUsername.rule))
        }
    }

    @Test
    func testRefusesAKeyFileThatIsMissingMultiLineOrHostile() async throws {
        let missing = directory.appendingPathComponent("nope.pub")
        let multi = try file("m.pub", "a\nb\n")
        let control = try file("c.pub", "ssh-ed25519 AA\u{1}A\n")
        let marker = try file("p.pub", "ssh-ed25519 PARBAKE_X\n")
        for key in [missing, multi, control, marker] {
            await #expect(throws: ValidationError.self, "\(key.lastPathComponent)") { try await validate(keys: [key]) }
        }
    }

    @Test(arguments: ["ALL", "/bin/sh -c x", "/usr/bin/*"])
    func testRefusesABadSudoEntry(command: String) async {
        await #expect(throws: ValidationError.self) { try await validate(sudo: [command]) }
    }

    @Test
    func testABadSudoEntryPrintsTheCodeAndQuotedMessage() async {
        do {
            try await validate(sudo: ["ALL"])
            Issue.record("expected a throw")
        } catch let error as ValidationError {
            #expect(
                error.message
                    == "invalidArgument: \"sudo command ALL must be an absolute command path with no arguments or wildcards, "
                    + "using only the characters A-Z a-z 0-9 . _ / + -\"")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test
    func testAHostileKeyPrintsTheCodeAndQuotedMessage() async throws {
        let key = try file("p.pub", "ssh-ed25519 PARBAKE_X\n")
        do {
            try await validate(keys: [key])
            Issue.record("expected a throw")
        } catch let error as ValidationError {
            #expect(error.message == "invalidArgument: \"public key in \(key.path) must not contain the text PARBAKE_\"")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test
    func testRefusesAMissingAgentBinary() async {
        let missing = directory.appendingPathComponent("no-agent").path
        await #expect(throws: ValidationError.self) { try await validate(agent: missing, noAgent: false) }
    }

    @Test
    func testAgentWithNoAgentConflicts() async throws {
        let agent = try file("agent", "bin")
        await #expect(throws: ValidationError.self) { try await validate(agent: agent.path, noAgent: true) }
    }

    @Test
    func testRefusesAnUnreadableScript() async {
        let missing = directory.appendingPathComponent("gone.sh")
        await #expect(throws: ValidationError.self) { try await validate(scripts: [missing]) }
    }

    @Test
    func testTheKeychainPreflightRunsWithTheService() async {
        nonisolated(unsafe) var service: String?
        await #expect(throws: RuntimeFailure.keychainLocked(service: "svc")) {
            try await validate(
                keychain: true,
                preflight: { name in
                    service = name
                    throw RuntimeFailure.keychainLocked(service: name)
                })
        }
        #expect(service == "svc")
    }

    @Test
    func testTheKeychainPreflightIsSkippedWithoutTheFlag() async throws {
        try await validate(keychain: false, preflight: { _ in throw RuntimeFailure.keychainLocked(service: "x") })
    }

    @Test
    func testTheKeychainPreflightPassesWhenItSucceeds() async throws {
        try await validate(keychain: true, preflight: { _ in })
    }

    @Test
    func testAnInvalidInputFailsBeforeTheDownload() async throws {
        let create = try ParbakeTool.Create.parse([
            "--bundle", directory.appendingPathComponent("VM.bundle").path, "--restore-image", "file:///nonexistent",
            "--username", "ci", "--sudo", "/bin/sh -c x", "--no-agent",
        ])
        await #expect(throws: ValidationError.self) { try await create.run() }
    }

    @Test(arguments: [
        ["--authorized-key", "k.pub"], ["--sudo", "/usr/bin/true"], ["--keychain"], ["--full-name", "CI"], ["--tidy"],
    ])
    func testAnAccountFlagNeedsAUsername(arguments: [String]) async throws {
        let create = try ParbakeTool.Create.parse(arguments)
        await #expect(throws: ValidationError.self) { try await create.validateAccount() }
    }

    @Test
    func testNoAccountFlagsAndNoUsernameIsValid() async throws {
        try await ParbakeTool.Create.parse([]).validateAccount()
    }

    @Test
    func testAPipedPasswordIsReadBeforeTheDownload() throws {
        let create = try ParbakeTool.Create.parse(["--username", "ci"])
        #expect(try create.readStdinPassword(isTerminal: false, read: { "secret" }) == "secret")
        #expect(try create.readStdinPassword(isTerminal: true, read: { "secret" }) == nil)
        let keychain = try ParbakeTool.Create.parse(["--username", "ci", "--keychain"])
        #expect(try keychain.readStdinPassword(isTerminal: false, read: { "secret" }) == nil)
        #expect(try ParbakeTool.Create.parse([]).readStdinPassword(isTerminal: false, read: { "secret" }) == nil)
    }
}
