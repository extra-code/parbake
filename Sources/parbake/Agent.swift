// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import RuntimeMacOS

extension ParbakeTool {
    struct Agent: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the guest agent in a VM bundle",
            subcommands: [Install.self]
        )
    }
}

extension ParbakeTool.Agent {
    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install or update the guest agent in a provisioned bundle",
            discussion: """
                Boots the bundle once, copies the agent from this build into the guest over SSH with the \
                bundle's guest key, and installs it as a LaunchDaemon with the account's password. Once \
                the agent answers over vsock, it records the agent's version in the bundle and shuts the \
                guest down through the agent.

                This writes to the bundle's disk image. Containers created from the bundle keep overlays \
                made against the old content: remove them before, and create them again afterwards.

                The password comes from the login keychain with --keychain, else from standard input, \
                or is prompted for on a terminal.
                """
        )

        @Option(name: .long, help: "Path of a provisioned VM bundle with a guest key")
        var bundle: String

        @Option(name: .long, help: "Agent executable to install (default: next to parbake)")
        var agent: String?

        @Flag(name: .long, help: "Take the account password from the login keychain")
        var keychain = false

        @Option(name: .long, help: "Keychain service of the stored password")
        var keychainService = GuestCredentials.defaultService

        @Option(name: .long, help: "Seconds to wait for the account to answer over SSH")
        var timeout: Int = 300

        func run() async throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            let vmBundle = try MacOSVMBundle(url: URL(fileURLWithPath: bundle))
            guard let username = vmBundle.provisionedUsername, let shell = vmBundle.guestShell else {
                throw ParbakeError.runtime("\(bundle) has no Provisioned account or GuestKey; run provision first")
            }
            let binary = try AgentSetup.binary(at: agent)
            let password = try await AgentSetup.password(for: username, keychainService: keychain ? keychainService : nil)

            let virtualMachine = try MacOSVirtualMachine(bundle: vmBundle, cpus: 4, memoryInBytes: 8 << 30)
            print("Booting \(bundle)")
            try await virtualMachine.start()
            do {
                let address = try await AgentSetup.waitForSSH(virtualMachine, shell: shell, timeout: timeout)
                print("\(username) answers over SSH at \(address)")
                try await AgentSetup.stage(binary, shell: shell, address: address)
                let result = await shell.run("/bin/bash -s", on: address, input: try GuestAgentInstallation.script(password: password))
                guard result.output.contains(GuestAgentInstallation.installedMarker) else {
                    throw ParbakeError.runtime(
                        "installing the agent failed (ssh exit status \(result.status)): "
                            + LogText.sanitized(result.errorOutput))
                }
                print("Installed the agent as the LaunchDaemon \(GuestAgentInstallation.label)")
                if try await !AgentSetup.confirmAndShutDown(virtualMachine: virtualMachine, bundle: vmBundle) {
                    _ = await shell.run(GuestCommands.shutdown, on: address)
                }
            } catch {
                try? await virtualMachine.forceStop()
                throw error
            }
            print("Shutting the guest down")
            try await AgentSetup.waitForStop(virtualMachine)
            print("Installed the guest agent in \(bundle)")
        }
    }
}
