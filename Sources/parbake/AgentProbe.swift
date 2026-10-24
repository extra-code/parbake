// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Containerization
import ContainerizationOCI
import Foundation
import NIOPosix
import ParbakeVersion
import RuntimeMacOS

extension ParbakeTool {
    struct AgentProbe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "agent-probe",
            abstract: "Check that the guest agent answers over vsock (development)",
            discussion: """
                Boots a throwaway instance of a provisioned bundle, copies the agent into the guest \
                over SSH with the bundle's guest key and starts it as the provisioned account, then \
                calls the agent through containerization's Vminitd client on vsock: Getenv for the \
                agent version and for HOME, Sync, and one call the agent does not implement. The \
                guest is shut down and the instance removed afterwards; the bundle stays unchanged.
                """,
            shouldDisplay: false
        )

        @Option(name: .long, help: "Path of a provisioned VM bundle with a guest key")
        var bundle: String

        @Option(name: .long, help: "Agent executable to copy into the guest (default: next to parbake)")
        var agent: String?

        @Option(name: .long, help: "Seconds to wait for SSH and then for the agent")
        var timeout: Int = 300

        func run() async throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            let source = try MacOSVMBundle(url: URL(fileURLWithPath: bundle))
            guard let shell = source.guestShell else {
                throw ParbakeError.runtime("\(bundle) has no Provisioned account or GuestKey")
            }
            let agentURL =
                agent.map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("parbake-agent")
            let agentBinary = try Data(contentsOf: agentURL)

            let instanceURL = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-probe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: instanceURL) }
            let instance = try source.instance(at: instanceURL)
            let instanceShell = instance.guestShell ?? shell

            let virtualMachine = try MacOSVirtualMachine(bundle: instance, cpus: 4, memoryInBytes: 8 << 30)
            let started = ContinuousClock.now
            try await virtualMachine.start()
            print("Booted a throwaway instance of \(bundle)")

            do {
                let address = try await AgentSetup.waitForSSH(virtualMachine, shell: instanceShell, timeout: timeout)
                print("SSH answers at \(address) after \(started.duration(to: .now))")

                let install = instanceShell.run(
                    "cat > /tmp/parbake-agent && chmod 755 /tmp/parbake-agent && "
                        + "(nohup /tmp/parbake-agent >/tmp/parbake-agent.log 2>&1 </dev/null &) && echo started",
                    on: address, input: agentBinary)
                guard install.output.contains("started") else {
                    throw ParbakeError.runtime("failed to start the agent in the guest: \(LogText.sanitized(install.errorOutput))")
                }
                print("Copied \(agentBinary.count / 1_000_000) MB agent into the guest and started it")

                let agentClient = try await dialAgent(virtualMachine)
                print("vsock port \(Vminitd.port) accepted a connection after \(started.duration(to: .now))")
                let version = try await agentClient.getenv(key: AgentVersionLine.variable)
                let home = try await agentClient.getenv(key: "HOME")
                print("Getenv \(AgentVersionLine.variable) = \(version)")
                print("Getenv HOME = \(home)")
                try await agentClient.sync()
                print("Sync succeeded")
                do {
                    try await agentClient.umount(path: "/", flags: 0)
                    print("Umount unexpectedly succeeded")
                } catch {
                    print("Umount failed as expected: \(error)")
                }
                try await probeProcesses(agentClient, virtualMachine: virtualMachine, username: source.provisionedUsername ?? "")
                try? await agentClient.close()

                let log = instanceShell.run("cat /tmp/parbake-agent.log", on: address)
                print("Agent log: \(log.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                _ = instanceShell.run(GuestCommands.shutdown, on: address)
            } catch {
                try? await virtualMachine.forceStop()
                throw error
            }
            var forceStopFailed = false
            _ = await GuestShutdown.run(
                virtualMachine, request: { true }, requestWait: .seconds(120), powerButtonWait: .seconds(60),
                note: { step, error in
                    forceStopFailed = forceStopFailed || step == .forceStop
                    AgentSetup.reportStopFailure(step, error)
                })
            if forceStopFailed {
                throw ParbakeError.runtime("the guest did not shut down and may still be running")
            }
            print("Guest stopped; removed the instance")
        }

        /// Spec V-2 and the process paths around it: separate streams and the exit code, standard
        /// input, a signal, and a refused account.
        private func probeProcesses(_ agent: Vminitd, virtualMachine: MacOSVirtualMachine, username: String) async throws {
            let account = ContainerizationOCI.User(username: username)

            let separate = try await run(
                agent, virtualMachine, id: "v2-streams", ports: (nil, 0x1000_0001, 0x1000_0002),
                process: Process(args: ["/bin/sh", "-c", "echo out; echo err >&2; exit 3"], user: account))
            print("V-2 streams: stdout \(separate.stdout.debugDescription), stderr \(separate.stderr.debugDescription), exit \(separate.exitCode)")
            guard separate.stdout == "out\n", separate.stderr == "err\n", separate.exitCode == 3 else {
                throw ParbakeError.runtime("the V-2 stream check failed")
            }

            let echoed = try await run(
                agent, virtualMachine, id: "v2-stdin", ports: (0x1000_0003, 0x1000_0004, nil),
                process: Process(args: ["cat"], user: account), input: "hello from the host\n")
            print("stdin: stdout \(echoed.stdout.debugDescription), exit \(echoed.exitCode)")

            let stdout = Task { try await virtualMachine.accept(onPort: 0x1000_0005, timeout: .seconds(30)) }
            try await agent.createProcess(
                id: "v2-signal", containerID: nil, stdinPort: nil, stdoutPort: 0x1000_0005, stderrPort: nil, ociRuntimePath: nil,
                configuration: Spec(process: Process(args: ["tail", "-f", "/dev/null"], user: account)), options: nil)
            let pid = try await agent.startProcess(id: "v2-signal", containerID: nil)
            _ = try await stdout.value
            try await agent.signalProcess(id: "v2-signal", containerID: nil, signal: SIGTERM)
            let signalled = try await agent.waitProcess(id: "v2-signal", containerID: nil)
            print("signal: pid \(pid) got SIGTERM, exit \(signalled.exitCode)")
            guard signalled.exitCode == 128 + SIGTERM else {
                throw ParbakeError.runtime("a process stopped by SIGTERM must exit \(128 + SIGTERM)")
            }
            try await agent.deleteProcess(id: "v2-signal", containerID: nil)

            do {
                try await agent.createProcess(
                    id: "v2-root", containerID: nil, stdinPort: nil, stdoutPort: nil, stderrPort: nil, ociRuntimePath: nil,
                    configuration: Spec(process: Process(args: ["id"])), options: nil)
                _ = try await agent.startProcess(id: "v2-root", containerID: nil)
                print("root: unexpectedly started")
            } catch {
                print("root: refused as expected: \(error)")
            }
        }

        private func run(
            _ agent: Vminitd, _ virtualMachine: MacOSVirtualMachine, id: String, ports: (UInt32?, UInt32?, UInt32?),
            process: ContainerizationOCI.Process, input: String = ""
        ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
            func accept(_ port: UInt32?) -> Task<FileHandle?, any Error> {
                Task {
                    guard let port else {
                        return nil
                    }
                    return try await virtualMachine.accept(onPort: port, timeout: .seconds(30))
                }
            }
            let stdin = accept(ports.0)
            let stdout = accept(ports.1)
            let stderr = accept(ports.2)
            try await agent.createProcess(
                id: id, containerID: nil, stdinPort: ports.0, stdoutPort: ports.1, stderrPort: ports.2, ociRuntimePath: nil,
                configuration: Spec(process: process), options: nil)
            _ = try await agent.startProcess(id: id, containerID: nil)
            if let handle = try await stdin.value {
                handle.write(Data(input.utf8))
                try handle.close()
            }
            let stdoutHandle = try await stdout.value
            let stderrHandle = try await stderr.value
            async let out = Task.detached { stdoutHandle?.readDataToEndOfFile() ?? Data() }.value
            async let err = Task.detached { stderrHandle?.readDataToEndOfFile() ?? Data() }.value
            let (outData, errData) = await (out, err)
            let exit = try await agent.waitProcess(id: id, containerID: nil)
            try await agent.deleteProcess(id: id, containerID: nil)
            return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), exit.exitCode)
        }

        private func dialAgent(_ virtualMachine: MacOSVirtualMachine) async throws -> Vminitd {
            var lastError: (any Error)?
            let agent = try await GuestReachability.poll(every: .seconds(1), timeout: .seconds(timeout)) { () async throws -> Vminitd? in
                do {
                    let handle = try await virtualMachine.connect(toPort: Vminitd.port)
                    return try await Vminitd(connection: handle, group: MultiThreadedEventLoopGroup.singleton)
                } catch {
                    lastError = error
                    return nil
                }
            }
            guard let agent else {
                throw ParbakeError.runtime("the agent did not accept a vsock connection: \(String(describing: lastError))")
            }
            return agent
        }
    }
}
