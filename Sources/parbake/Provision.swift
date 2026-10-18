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
                and waits until the account answers over SSH. In one SSH session it then adds the guest \
                key that the runtime uses (and a public key from --authorized-key), allows the account to \
                run /sbin/shutdown without a password, optionally turns Spotlight off and empties the \
                caches (--tidy), and shuts the guest down. Run it on the first boot after `install`: the guest ignores \
                the account settings on every later boot.

                The password is read from standard input, or prompted for on a terminal. With \
                --keychain it comes from the login keychain instead; when the keychain has none for \
                the username, a random one is generated and stored there first.
                """
        )

        @Option(name: .long, help: "Path of the VM bundle to provision")
        var bundle: String

        @Option(name: .long, help: "Username of the account to create")
        var username: String

        @Option(name: .long, help: "Full name of the account (default: the username)")
        var fullName: String?

        @Option(name: .long, help: "Public key file to add to the account's authorized_keys")
        var authorizedKey: String?

        @Flag(name: .long, help: "Take the password from the login keychain, generating and storing one when it has none")
        var keychain = false

        @Option(name: .long, help: "Keychain service of the stored password")
        var keychainService = GuestCredentials.defaultService

        @Flag(name: .long, help: "Turn Spotlight indexing off and empty the caches before the shutdown")
        var tidy = false

        @Option(name: .long, help: "Number of CPUs during provisioning")
        var cpus: Int = 4

        @Option(name: .long, help: "Memory in GiB during provisioning")
        var memory: UInt64 = 8

        @Option(name: .long, help: "Seconds to wait for the account to answer over SSH")
        var timeout: Int = 900

        func run() async throws {
            guard username.range(of: "^[a-z_][a-z0-9_-]*$", options: .regularExpression) != nil else {
                throw ValidationError("the username must be lowercase letters, digits, '_' or '-'")
            }
            let vmBundle = try MacOSVMBundle(url: URL(fileURLWithPath: bundle))
            guard !FileManager.default.fileExists(atPath: vmBundle.provisionedURL.path) else {
                throw ValidationError("\(bundle) is already provisioned")
            }
            var publicKeys = try authorizedKey.map { [try Self.publicKey(at: URL(fileURLWithPath: $0))] } ?? []
            let password = try keychain
                ? GuestCredentials(service: keychainService).passwordCreatingIfNeeded(for: username)
                : readPassword()

            let provisioning = GuestProvisioning(fullName: fullName ?? username, username: username, password: password)
            let startOptions = try provisioning.startOptions()
            publicKeys.append(try Self.createGuestKey(at: vmBundle.guestKeyURL))

            let virtualMachine = try MacOSVirtualMachine(bundle: vmBundle, cpus: cpus, memoryInBytes: memory << 30)
            print("Booting \(bundle) to create the account \(username)")
            try await virtualMachine.start(options: startOptions)

            let ssh = GuestShell(username: username, credential: .password(password))
            let address: String
            do {
                address = try await waitForAccount(virtualMachine: virtualMachine, ssh: ssh)
            } catch {
                try? await virtualMachine.forceStop()
                throw error
            }
            print("The account answers over SSH at \(address)")

            let script = GuestPreparation.script(username: username, password: password, publicKeys: publicKeys, tidy: tidy)
            let result = ssh.run("/bin/bash -s", on: address, input: script)
            guard result.output.contains(GuestPreparation.preparedMarker) else {
                try? await virtualMachine.forceStop()
                throw ValidationError("preparing the account failed (ssh exit status \(result.status))")
            }
            print("Added \(publicKeys.count) public key(s), allowed \(username) to shut the guest down\(tidy ? ", turned Spotlight off and emptied the caches" : "")")

            print("Shutting the guest down")
            if await virtualMachine.wait(timeout: .seconds(180)) == nil {
                try? await virtualMachine.requestStop()
                if await virtualMachine.wait(timeout: .seconds(60)) == nil {
                    try? await virtualMachine.forceStop()
                    throw ValidationError("the guest did not shut down; it was stopped forcibly and may need another boot")
                }
            }

            try Data((username + "\n").utf8).write(to: vmBundle.provisionedURL)
            print("Provisioned \(bundle) with the account \(username)")
        }

        /// The single-line public key in `url`.
        static func publicKey(at url: URL) throws -> String {
            let key = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains("\n"), !key.contains("PARBAKE_") else {
                throw ValidationError("\(url.path) must hold one public key on one line")
            }
            return key
        }

        /// Creates the guest key pair, or reuses it from an interrupted run, and returns its public key.
        static func createGuestKey(at url: URL) throws -> String {
            if !FileManager.default.fileExists(atPath: url.path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "parbake", "-f", url.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw ValidationError("ssh-keygen failed to create \(url.path)")
                }
            }
            return try publicKey(at: url.appendingPathExtension("pub"))
        }

        /// Polls the DHCP leases and SSH until the account logs in, the guest stops, or the timeout passes.
        private func waitForAccount(virtualMachine: MacOSVirtualMachine, ssh: GuestShell) async throws -> String {
            let deadline = ContinuousClock.now + .seconds(timeout)
            while ContinuousClock.now < deadline {
                if let exit = virtualMachine.currentExit {
                    throw ValidationError("the guest stopped during provisioning with exit code \(exit.exitCode)")
                }
                if let address = DHCPLeases.currentAddress(for: virtualMachine.macAddress), ssh.run("true", on: address).status == 0 {
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
