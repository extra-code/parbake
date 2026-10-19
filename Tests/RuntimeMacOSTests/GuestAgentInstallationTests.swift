// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

struct GuestAgentInstallationTests {
    /// Runs `tool arguments` with `input` on standard input and returns its exit status.
    private func status(of tool: String, _ arguments: [String], input: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test
    func testTheInstallationScriptAndItsRootCommandsParse() throws {
        #expect(try status(of: "/bin/bash", ["-n"], input: GuestAgentInstallation.script(password: "pa$$ 'word")) == 0)
        #expect(try status(of: "/bin/sh", ["-n"], input: GuestAgentInstallation.rootCommands) == 0)
    }

    @Test
    func testThePropertyListIsValid() throws {
        #expect(try status(of: "/usr/bin/plutil", ["-lint", "-s", "-"], input: GuestAgentInstallation.propertyList) == 0)
    }

    @Test
    func testThePreparationInstallsTheAgentAndLeavesTheShutdownToTheHost() throws {
        let script = GuestPreparation.script(username: "ci", password: "x", publicKeys: ["k"], tidy: false, installAgent: true)
        #expect(try status(of: "/bin/bash", ["-n"], input: script) == 0)
        #expect(script.contains("launchctl bootstrap system \(GuestAgentInstallation.propertyListPath)"))
        #expect(!script.contains("sudo -n /sbin/shutdown -h now"))
        let lines = script.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.last == "echo '\(GuestPreparation.preparedMarker)'")
    }
}
