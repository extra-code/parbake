// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Darwin
import Foundation
import ParbakeVersion
import RuntimeMacOS

@main
struct ParbakeTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parbake",
        abstract: "Create macOS VM bundles for container-runtime-macos",
        version: Parbake.release,
        subcommands: [
            Agent.self,
            AgentProbe.self,
            Create.self,
            Install.self,
            Layer.self,
            Provision.self,
            Setup.self,
            StateProbe.self,
        ]
    )

    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let command: any ParsableCommand
        do {
            command = try parseAsRoot()
        } catch {
            exit(withError: error)
        }
        do {
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                var syncCommand = command
                try syncCommand.run()
            }
        } catch {
            if ParbakeTool.exitCode(for: error) == .success { exit(withError: error) }
            if error is ValidationError || error is ExitCode || error is CleanExit { exit(withError: error) }
            let line = "Error: \(ParbakeExit.message(for: error))"
            FileHandle.standardError.write(Data((line + "\n").utf8))
            LogSubsystem.logger(category: "parbake").error("\(line, privacy: .public)")
            Darwin.exit(ParbakeExit.code(for: error))
        }
    }
}
