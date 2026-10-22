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
        public let timedOut: Bool

        public init(status: Int32, output: String, errorOutput: String, timedOut: Bool = false) {
            self.status = status
            self.output = output
            self.errorOutput = errorOutput
            self.timedOut = timedOut
        }
    }

    public let username: String
    public let credential: Credential

    /// The ssh client; tests pass a stub.
    let sshPath: String

    public init(username: String, credential: Credential) {
        self.init(username: username, credential: credential, sshPath: "/usr/bin/ssh")
    }

    init(username: String, credential: Credential, sshPath: String) {
        self.username = username
        self.credential = credential
        self.sshPath = sshPath
    }

    /// Runs `command` on `address` and returns ssh's exit status, the command's standard output
    /// and ssh's standard error; `input` goes to its standard input.
    public func run(_ command: String, on address: String, input: String = "", timeout: Duration = .seconds(300)) -> Result {
        run(command, on: address, input: Data(input.utf8), timeout: timeout)
    }

    /// The ssh argument list for `command`, or nil when `username` or `address` is not valid.
    public static func arguments(username: String, address: String, credential: Credential, command: String) -> [String]? {
        guard GuestUsername(rawValue: username) != nil, IPv4Address.isValid(address) else { return nil }
        var arguments = [
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=5",
            "-o", "ForwardAgent=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "IdentityAgent=none",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
        ]
        switch credential {
        case .password:
            arguments += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        case .key(let key):
            arguments += [
                "-i", key.path,
                "-o", "IdentitiesOnly=yes",
                "-o", "BatchMode=yes",
            ]
        }
        arguments += ["-l", username, "--", address, command]
        return arguments
    }

    private final class Captured: @unchecked Sendable {
        var output = Data()
        var errorOutput = Data()
    }

    /// Runs `command` on `address` with `input` as its standard input, which may be binary.
    /// After `timeout` the child gets SIGTERM, then SIGKILL two seconds later.
    public func run(_ command: String, on address: String, input: Data, timeout: Duration = .seconds(300)) -> Result {
        guard let arguments = Self.arguments(username: username, address: address, credential: credential, command: command) else {
            return Result(status: -1, output: "", errorOutput: "invalid guest username or address", timedOut: false)
        }
        let failed = Result(status: -1, output: "", errorOutput: "")
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        var directory: URL?
        defer {
            if let directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        if case .password(let password) = credential {
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
            environment["SSH_ASKPASS"] = askpass.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["PARBAKE_SSH_PASSWORD"] = password
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = arguments
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return failed
        }

        // Each pipe has its own thread, so none fills while another is serviced.
        let captured = Captured()
        let threads = DispatchGroup()
        let writer = stdin.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        for (pipe, isOutput) in [(stdout, true), (stderr, false)] {
            threads.enter()
            Thread {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOutput { captured.output = data } else { captured.errorOutput = data }
                threads.leave()
            }.start()
        }
        threads.enter()
        Thread {
            try? writer.write(contentsOf: input)
            try? writer.close()
            threads.leave()
        }.start()

        var timedOut = false
        if exited.wait(timeout: .now() + Self.seconds(timeout)) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        threads.wait()
        return Result(
            status: timedOut ? -1 : process.terminationStatus,
            output: String(decoding: captured.output, as: UTF8.self),
            errorOutput: String(decoding: captured.errorOutput, as: UTF8.self),
            timedOut: timedOut
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
