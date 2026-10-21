// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import ContainerizationOCI
import Darwin
import Foundation
import RuntimeMacOS

/// Runs shell scripts as root in a bundle's guest through the agent, for `layer` and `create`.
enum GuestScript {
    /// Boots `bundle`, runs each script in `scripts` in order with its output in the terminal, and
    /// shuts the guest down through the agent. The first script that exits non-zero fails the run.
    static func run(_ scripts: [URL], in bundle: MacOSVMBundle, cpus: Int, memory: UInt64, timeout: Int) async throws {
        for script in scripts where !FileManager.default.isReadableFile(atPath: script.path) {
            throw ValidationError("cannot read the script \(script.path)")
        }
        let virtualMachine = try MacOSVirtualMachine(bundle: bundle, cpus: cpus, memoryInBytes: memory << 30)
        print("==> Booting \(bundle.url.lastPathComponent)")
        try await virtualMachine.start()
        let agent = GuestAgent(virtualMachine: virtualMachine)
        do {
            _ = try await agent.waitUntilReady(timeout: .seconds(timeout))
            for script in scripts {
                print("==> Running \(script.lastPathComponent) as root")
                let code = try await run(script, agent: agent)
                guard code == 0 else {
                    throw ValidationError("\(script.lastPathComponent) exited with \(code)")
                }
            }
            print("==> Shutting the guest down")
            let accepted = await agent.shutDown(provisionedUsername: bundle.provisionedUsername, timeout: .seconds(15)) { print($0) }
            await agent.close()
            if !accepted {
                try? await virtualMachine.requestStop()
            }
        } catch {
            await agent.close()
            try? await virtualMachine.forceStop()
            throw error
        }
        try await AgentSetup.waitForStop(virtualMachine)
    }

    private static func run(_ script: URL, agent: GuestAgent) async throws -> Int32 {
        let id = "script-\(UUID().uuidString)"
        let process = ContainerizationOCI.Process(args: ["/bin/bash", "-s"], cwd: "/", user: User(username: "root"))
        let input = try FileHandle(forReadingFrom: script)
        // The agent closes the output handles when the script's output ends; duplicates keep
        // parbake's own standard output and error open for what follows.
        let output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        let errorOutput = FileHandle(fileDescriptor: dup(STDERR_FILENO), closeOnDealloc: true)
        try await agent.createProcess(id: id, process: process, stdio: [input, output, errorOutput])
        _ = try await agent.startProcess(id: id)
        return try await agent.wait(id: id).exitCode
    }
}
