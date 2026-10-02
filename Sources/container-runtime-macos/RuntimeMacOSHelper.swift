// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser

@main
struct RuntimeMacOSHelper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-runtime-macos",
        abstract: "XPC Service for managing a macOS sandbox",
        version: "0.1.0",
        subcommands: [
            Start.self
        ]
    )
}
