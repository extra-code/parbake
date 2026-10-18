// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Runs commands in a guest over SSH.
///
/// With a password, ssh reads it from an askpass helper that prints it from the environment, so
/// it never appears in an argument list. With a key, ssh authenticates with that key only.
public struct GuestShell: Sendable {
    public enum Credential: Sendable {
        case password(String)
        case key(URL)
    }

    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public let errorOutput: String
    }

    public let username: String
    public let credential: Credential

    public init(username: String, credential: Credential) {
        self.username = username
        self.credential = credential
    }

    /// Runs `command` on `address` and returns ssh's exit status, the command's standard output
    /// and ssh's standard error; `input` goes to its standard input.
    public func run(_ command: String, on address: String, input: String = "") -> Result {
        run(command, on: address, input: Data(input.utf8))
    }

    /// Runs `command` on `address` with `input` as its standard input, which may be binary.
    public func run(_ command: String, on address: String, input: Data) -> Result {
        let failed = Result(status: -1, output: "", errorOutput: "")
        var arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=5",
        ]
        var environment = ProcessInfo.processInfo.environment
        var directory: URL?
        defer {
            if let directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        switch credential {
        case .password(let password):
            let helperDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-\(UUID().uuidString)")
            let askpass = helperDirectory.appendingPathComponent("askpass")
            do {
                try FileManager.default.createDirectory(
                    at: helperDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                directory = helperDirectory
                try Data("#!/bin/sh\nprintf '%s\\n' \"$PARBAKE_SSH_PASSWORD\"\n".utf8).write(to: askpass)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
            } catch {
                return failed
            }
            arguments += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "NumberOfPasswordPrompts=1",
            ]
            environment["SSH_ASKPASS"] = askpass.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["PARBAKE_SSH_PASSWORD"] = password
        case .key(let key):
            arguments += [
                "-i", key.path,
                "-o", "IdentitiesOnly=yes",
                "-o", "BatchMode=yes",
            ]
        }
        arguments += ["\(username)@\(address)", command]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return failed
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        // Drains standard error on its own thread, so neither pipe fills while the other is read.
        nonisolated(unsafe) var errorData = Data()
        let errorReader = Thread { errorData = stderr.fileHandleForReading.readDataToEndOfFile() }
        errorReader.start()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        while !errorReader.isFinished { usleep(10_000) }
        return Result(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self),
            errorOutput: String(decoding: errorData, as: UTF8.self)
        )
    }
}
