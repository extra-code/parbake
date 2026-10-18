// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser

@main
struct ParbakeTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parbake",
        abstract: "Create macOS VM bundles for container-runtime-macos",
        version: "0.1.0",
        subcommands: [
            AgentProbe.self,
            IPSWURL.self,
            Install.self,
            Provision.self,
            Setup.self,
        ]
    )
}
