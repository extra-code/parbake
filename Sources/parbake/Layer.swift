// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import ContainerizationOCI
import Foundation
import RuntimeMacOS

extension ParbakeTool {
    struct Layer: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a layer bundle: a base bundle plus what a script installs, such as Xcode",
            discussion: """
                Creates a layer bundle that links the base bundle's disk image and writes into a layer \
                of its own, boots it, runs the script as root through the guest agent, and shuts the \
                guest down. The script reads from standard input of /bin/bash; its output appears here. \
                The base bundle stays unchanged.

                Containers run from the layer bundle like from any bundle, with \
                --label runtime-macos.bundle=<layer bundle>: they read base and layer and write to an \
                overlay of their own. A layer bundle cannot be the base of another layer.

                The base bundle needs the guest agent. Rebuilding the base, or the layer with --replace, \
                makes the layers and overlays made on the old one unusable, as a rebuilt bundle does.
                """
        )

        @Option(name: .long, help: "Base bundle the layer stacks on (default: $PARBAKE_HOME/VM.bundle, else ~/VM.bundle)")
        var base: String?

        @Option(name: .long, help: "Layer bundle to create")
        var bundle: String

        @Option(name: .long, help: "Shell script to run as root in the guest")
        var script: String

        @Flag(name: .long, help: "Replace an existing layer bundle once the new one is complete")
        var replace = false

        @Option(name: .long, help: "Number of CPUs while the script runs")
        var cpus: Int = 4

        @Option(name: .long, help: "Memory in GiB while the script runs")
        var memory: UInt64 = 8

        @Option(name: .long, help: "Seconds to wait for the guest agent after the boot")
        var timeout: Int = 300

        func run() async throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            let baseBundle = try MacOSVMBundle(url: URL(fileURLWithPath: base ?? ParbakeHome().defaultBundle.path))
            guard baseBundle.agentVersion != nil else {
                throw ValidationError("\(baseBundle.url.path) has no guest agent; run parbake agent install first")
            }
            let scriptURL = URL(fileURLWithPath: script)
            guard FileManager.default.isReadableFile(atPath: scriptURL.path) else {
                throw ValidationError("cannot read the script \(scriptURL.path)")
            }
            let target = URL(fileURLWithPath: bundle)
            try await BundleReplacement.build(at: target, replacing: replace) { path in
                print("==> Creating a layer on \(baseBundle.url.path) in \(path.path)")
                let layer = try baseBundle.layerBundle(at: path)
                try await runScript(scriptURL, in: layer)
            }
            print("==> Created \(target.path)")
            print("Run a container from it with --label runtime-macos.bundle=\(target.path)")
        }

        private func runScript(_ scriptURL: URL, in layer: MacOSVMBundle) async throws {
            let virtualMachine = try MacOSVirtualMachine(bundle: layer, cpus: cpus, memoryInBytes: memory << 30)
            print("==> Booting the layer bundle")
            try await virtualMachine.start()
            let agent = GuestAgent(virtualMachine: virtualMachine)
            do {
                _ = try await agent.waitUntilReady(timeout: .seconds(timeout))
                print("==> Running \(scriptURL.lastPathComponent) as root")
                let id = "layer-\(UUID().uuidString)"
                let process = ContainerizationOCI.Process(args: ["/bin/bash", "-s"], cwd: "/", user: User(username: "root"))
                let input = try FileHandle(forReadingFrom: scriptURL)
                // The agent closes the output handles when the script's output ends; duplicates
                // keep parbake's own standard output and error open for what follows.
                let output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
                let errorOutput = FileHandle(fileDescriptor: dup(STDERR_FILENO), closeOnDealloc: true)
                try await agent.createProcess(id: id, process: process, stdio: [input, output, errorOutput])
                _ = try await agent.startProcess(id: id)
                let exit = try await agent.wait(id: id)
                guard exit.exitCode == 0 else {
                    throw ValidationError("\(scriptURL.lastPathComponent) exited with \(exit.exitCode); the layer was not kept")
                }
                print("==> Shutting the guest down")
                let accepted = await agent.shutDown(provisionedUsername: layer.provisionedUsername, timeout: .seconds(15)) { print($0) }
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
    }
}
