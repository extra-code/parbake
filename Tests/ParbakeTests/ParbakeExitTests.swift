// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import ContainerizationError
import Foundation
import RuntimeMacOS
import Testing

@testable import parbake

struct ParbakeExitTests {
    struct Row: Sendable {
        let error: any Error
        let code: Int32
    }

    static let rows: [Row] = [
        Row(error: ParbakeError.runtime("boom"), code: 1),
        Row(error: ParbakeError.scriptFailed(name: "setup.sh", status: 2), code: 3),
        Row(error: ValidationError("bad"), code: 64),
        Row(error: ParbakeError.failure(.bundleMissing(path: "/b", missing: nil)), code: 66),
        Row(error: ParbakeError.failure(.vmLimitReached), code: 69),
        Row(error: ParbakeError.failure(.keychainLocked(service: "s")), code: 69),
        Row(error: ParbakeError.failure(.keychainRefused(service: "s", status: -128)), code: 69),
        Row(error: ParbakeError.failure(.lockHeld(path: "/p", holder: nil)), code: 75),
        Row(error: ParbakeError.failure(.dhcpTimeout(macAddress: "m", seconds: 1, leaseFile: "/l")), code: 75),
        Row(error: ParbakeError.failure(.sshTimeout(username: "u", address: "a", seconds: 1)), code: 75),
        Row(error: ParbakeError.failure(.agentTimeout(seconds: 1, label: nil)), code: 75),
        Row(error: RuntimeFailure.vmLimitReached, code: 69),
        Row(error: ParbakeError.failure(.guestStopped(exitCode: 1)), code: 1),
        Row(error: RuntimeFailure.guestStopped(exitCode: nil), code: 1),
    ]

    @Test(arguments: rows)
    func testTheExitCode(row: Row) {
        #expect(ParbakeExit.code(for: row.error) == row.code)
    }

    @Test
    func testAnUnlistedErrorIsOne() {
        struct Other: Error {}
        #expect(ParbakeExit.code(for: Other()) == 1)
    }

    @Test
    func testARuntimeFailureMessageHasNoUsage() {
        let message = ParbakeExit.message(for: ParbakeError.failure(.vmLimitReached))
        #expect(!message.contains("Usage:"))
        #expect(message.contains("two macOS guests"))
    }

    @Test
    func testAScriptFailureNamesTheScriptAndStatus() {
        let message = ParbakeExit.message(for: ParbakeError.scriptFailed(name: "setup.sh", status: 2))
        #expect(message.contains("setup.sh"))
        #expect(message.contains("exited with 2"))
        #expect(!message.contains("Usage:"))
    }
}

extension ParbakeExitTests {
    @Test
    func testHelpAndVersionClassifyAsSuccess() async {
        for arguments in [["--help"], ["create", "--help"], ["--version"]] {
            do {
                var command = try ParbakeTool.parseAsRoot(arguments)
                if var asyncCommand = command as? any AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
                Issue.record("\(arguments) ran to completion")
            } catch {
                #expect(ParbakeTool.exitCode(for: error) == .success, "\(arguments)")
            }
        }
    }

    @Test
    func testAMissingBundleExits66() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())")
        do {
            _ = try MacOSVMBundle(url: missing)
            Issue.record("opened a missing bundle")
        } catch {
            #expect(ParbakeExit.code(for: error) == 66)
        }
    }

    @Test
    func testAMissingRestoreImageExits66BeforeAnyWork() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).ipsw").path
        let create = try ParbakeTool.Create.parse(["--restore-image", path])
        do {
            try create.validateRestoreImage()
            Issue.record("accepted a missing restore image")
        } catch {
            #expect(ParbakeExit.code(for: error) == 66)
            #expect(!ParbakeExit.message(for: error).contains("parbake create"))
        }
    }

    @Test
    func testAContainerizationErrorExitsOne() {
        #expect(ParbakeExit.code(for: ContainerizationError(.notFound, message: "x")) == 1)
        #expect(ParbakeExit.code(for: ContainerizationError(.invalidState, message: "x")) == 1)
    }

    @Test
    func testAPreconditionFailureIsARuntimeErrorWithoutUsage() {
        let error = ParbakeError.runtime("already provisioned")
        #expect(ParbakeExit.code(for: error) == 1)
        #expect(!ParbakeExit.message(for: error).contains("Usage:"))
    }

    @Test
    func testTheBuiltBinaryPrintsHelpAndVersionToStdout() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/parbake")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        for arguments in [["--help"], ["create", "--help"], ["--version"]] {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(arguments)")
            #expect(!output.isEmpty, "\(arguments)")
            #expect(errors.isEmpty, "\(arguments)")
        }
    }
}
