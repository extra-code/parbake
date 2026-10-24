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
    public func run(_ command: String, on address: String, input: String = "", timeout: Duration = .seconds(300)) async -> Result {
        await run(command, on: address, input: Data(input.utf8), timeout: timeout)
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

    /// The environment ssh runs in: a fixed `PATH`, the user's home and, for a password, the askpass
    /// helper that prints the password from the environment.
    static func environment(askpass: URL, password: String?) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        if let password {
            environment["SSH_ASKPASS"] = askpass.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["PARBAKE_SSH_PASSWORD"] = password
        }
        return environment
    }

    /// Runs `command` on `address` with `input` as its standard input, which may be binary.
    /// After `timeout` ssh gets SIGTERM, then SIGKILL two seconds later. Cancelling the calling task
    /// terminates ssh the same way and returns what it had printed.
    public func run(_ command: String, on address: String, input: Data, timeout: Duration = .seconds(300)) async -> Result {
        guard let invocation = prepare(command, on: address) else { return Self.invalidTarget }
        defer { invocation.cleanUp() }
        guard let environment = invocation.environment else { return Self.failed }
        do {
            let output = try await HostProcess.run(
                URL(fileURLWithPath: sshPath), arguments: invocation.arguments, environment: environment, input: input,
                timeout: timeout)
            return Self.result(output)
        } catch {
            return Self.failed
        }
    }

    /// The same as `run(_:on:input:timeout:)`.
    public func runCancellable(_ command: String, on address: String, input: Data, timeout: Duration = .seconds(300)) async -> Result {
        await run(command, on: address, input: input, timeout: timeout)
    }

    /// The same as `run(_:on:input:timeout:)` with text as standard input.
    public func runCancellable(_ command: String, on address: String, input: String = "", timeout: Duration = .seconds(300)) async -> Result {
        await run(command, on: address, input: Data(input.utf8), timeout: timeout)
    }

    private static let invalidTarget = Result(status: -1, output: "", errorOutput: "invalid guest username or address")
    private static let failed = Result(status: -1, output: "", errorOutput: "")

    /// A timeout reports -1, so callers need not know the signal that ended ssh.
    private static func result(_ output: ProcessOutput) -> Result {
        Result(
            status: output.timedOut ? -1 : output.status,
            output: String(decoding: output.output, as: UTF8.self),
            errorOutput: String(decoding: output.errorOutput, as: UTF8.self),
            timedOut: output.timedOut)
    }

    /// The argument list and environment of one ssh run, and the directory holding its askpass helper.
    /// A nil `environment` means the helper could not be written.
    private struct Invocation {
        let arguments: [String]
        let environment: [String: String]?
        let directory: URL?

        func cleanUp() {
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private func prepare(_ command: String, on address: String) -> Invocation? {
        guard let arguments = Self.arguments(username: username, address: address, credential: credential, command: command) else {
            return nil
        }
        guard case .password(let password) = credential else {
            return Invocation(
                arguments: arguments, environment: Self.environment(askpass: URL(fileURLWithPath: "/"), password: nil), directory: nil)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-\(UUID().uuidString)")
        let askpass = directory.appendingPathComponent("askpass")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("#!/bin/sh\nprintf '%s\\n' \"$PARBAKE_SSH_PASSWORD\"\n".utf8).write(to: askpass)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return Invocation(arguments: arguments, environment: nil, directory: nil)
        }
        return Invocation(arguments: arguments, environment: Self.environment(askpass: askpass, password: password), directory: directory)
    }
}
