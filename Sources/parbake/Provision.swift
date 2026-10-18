// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Darwin
import Foundation
import RuntimeMacOS

extension ParbakeTool {
    struct Provision: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set up a freshly installed macOS 27 or later guest without the Setup Assistant",
            discussion: """
                Boots the bundle once, headless, with a user account, automatic login and Remote Login, \
                waits until the account answers over SSH, optionally adds a public key for that account, \
                and shuts the guest down. Run it on the first boot after `install`: the guest ignores \
                the account settings on every later boot.

                The password is read from standard input, or prompted for on a terminal.
                """
        )

        /// The file a provisioned bundle carries; its content is the username.
        static let markerName = "Provisioned"

        @Option(name: .long, help: "Path of the VM bundle to provision")
        var bundle: String

        @Option(name: .long, help: "Username of the account to create")
        var username: String

        @Option(name: .long, help: "Full name of the account (default: the username)")
        var fullName: String?

        @Option(name: .long, help: "Public key file to add to the account's authorized_keys")
        var authorizedKey: String?

        @Option(name: .long, help: "Number of CPUs during provisioning")
        var cpus: Int = 4

        @Option(name: .long, help: "Memory in GiB during provisioning")
        var memory: UInt64 = 8

        @Option(name: .long, help: "Seconds to wait for the account to answer over SSH")
        var timeout: Int = 900

        func run() async throws {
            let vmBundle = try MacOSVMBundle(url: URL(fileURLWithPath: bundle))
            let marker = vmBundle.url.appendingPathComponent(Self.markerName)
            guard !FileManager.default.fileExists(atPath: marker.path) else {
                throw ValidationError("\(bundle) is already provisioned")
            }
            let publicKey = try authorizedKey.map { try String(contentsOfFile: $0, encoding: .utf8) }
            let password = try readPassword()

            let provisioning = GuestProvisioning(fullName: fullName ?? username, username: username, password: password)
            let startOptions = try provisioning.startOptions()

            let virtualMachine = try MacOSVirtualMachine(bundle: vmBundle, cpus: cpus, memoryInBytes: memory << 30)
            print("Booting \(bundle) to create the account \(username)")
            try await virtualMachine.start(options: startOptions)

            let ssh = GuestSSH(username: username, password: password)
            let address: String
            do {
                address = try await waitForAccount(virtualMachine: virtualMachine, ssh: ssh)
            } catch {
                try? await virtualMachine.forceStop()
                throw error
            }
            print("The account answers over SSH at \(address)")

            if let publicKey {
                let script = "umask 077 && mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
                guard ssh.run(script, on: address, input: publicKey.hasSuffix("\n") ? publicKey : publicKey + "\n") == 0 else {
                    try? await virtualMachine.forceStop()
                    throw ValidationError("failed to add the public key to ~/.ssh/authorized_keys")
                }
                print("Added the public key to ~/.ssh/authorized_keys")
            }

            print("Shutting the guest down")
            _ = ssh.run("sudo -S -p '' /sbin/shutdown -h now", on: address, input: password + "\n")
            if await virtualMachine.wait(timeout: .seconds(180)) == nil {
                try? await virtualMachine.requestStop()
                if await virtualMachine.wait(timeout: .seconds(60)) == nil {
                    try? await virtualMachine.forceStop()
                    throw ValidationError("the guest did not shut down; it was stopped forcibly and may need another boot")
                }
            }

            try Data((username + "\n").utf8).write(to: marker)
            print("Provisioned \(bundle) with the account \(username)")
        }

        /// Polls the DHCP leases and SSH until the account logs in, the guest stops, or the timeout passes.
        private func waitForAccount(virtualMachine: MacOSVirtualMachine, ssh: GuestSSH) async throws -> String {
            let deadline = ContinuousClock.now + .seconds(timeout)
            while ContinuousClock.now < deadline {
                if let exit = virtualMachine.currentExit {
                    throw ValidationError("the guest stopped during provisioning with exit code \(exit.exitCode)")
                }
                if let address = DHCPLeases.currentAddress(for: virtualMachine.macAddress), ssh.run("true", on: address) == 0 {
                    return address
                }
                try await Task.sleep(for: .seconds(5))
            }
            throw ValidationError("the account did not answer over SSH within \(timeout) seconds")
        }

        private func readPassword() throws -> String {
            if isatty(STDIN_FILENO) != 0 {
                var buffer = [CChar](repeating: 0, count: 1024)
                guard let line = readpassphrase("Password for \(username): ", &buffer, buffer.count, 0) else {
                    throw ValidationError("failed to read the password")
                }
                return String(cString: line)
            }
            guard let line = readLine(strippingNewline: true), !line.isEmpty else {
                throw ValidationError("no password on standard input")
            }
            return line
        }
    }
}

/// Runs commands in the guest over SSH with password authentication.
///
/// ssh reads the password from an askpass helper that prints it from the environment, so it
/// never appears in an argument list.
struct GuestSSH {
    let username: String
    let password: String

    /// Runs `command` on `address` and returns ssh's exit status; `input` goes to its standard input.
    func run(_ command: String, on address: String, input: String = "") -> Int32 {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let askpass = directory.appendingPathComponent("askpass")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("#!/bin/sh\nprintf '%s\\n' \"$PARBAKE_SSH_PASSWORD\"\n".utf8).write(to: askpass)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        } catch {
            return -1
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=5",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "NumberOfPasswordPrompts=1",
            "\(username)@\(address)",
            command,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["PARBAKE_SSH_PASSWORD"] = password
        process.environment = environment

        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
