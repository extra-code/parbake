// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import ContainerizationOCI
import Foundation
import RuntimeMacOS
import Virtualization

extension ParbakeTool {
    struct StateProbe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "state-probe",
            abstract: "Measure starting a guest from a saved state against a cold boot",
            discussion: """
                A development probe. It creates an instance of the bundle in the work directory, \
                boots it and times the boot until the guest agent answers, saves the guest's state, \
                and then restores that state into new instances: one on a clone of the overlay as it \
                was at the save, one on a fresh overlay, and one with another machine identifier. \
                For each it prints whether the restore worked and how long the agent took to answer. \
                The bundle stays unchanged; the work directory is removed at the end.
                """,
            shouldDisplay: false
        )

        @Option(name: .long, help: "Provisioned bundle with the guest agent")
        var bundle: String

        @Option(name: .long, help: "Directory for the instances and the state file, on the bundle's volume")
        var workDir: String

        @Option(name: .long, help: "Memory in GiB, which is also the size of the state file")
        var memory: UInt64 = 4

        @Option(name: .long, help: "Seconds to wait for the guest agent")
        var timeout: Int = 300

        @Flag(name: .long, help: "Boot the bundle itself, without an overlay, and restore into it; writes to the bundle's disk")
        var direct = false

        func run() async throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            let base = try MacOSVMBundle(url: URL(fileURLWithPath: bundle))
            guard base.agentVersion != nil else {
                throw ParbakeError.runtime("\(bundle) has no guest agent")
            }
            let work = URL(fileURLWithPath: workDir)
            guard !FileManager.default.fileExists(atPath: work.path) else {
                throw ValidationError("\(work.path) already exists")
            }
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            let state = work.appendingPathComponent("State.vzvmsave")
            let saved = direct ? base : try base.instance(at: work.appendingPathComponent("saved"))
            let cold = try MacOSVirtualMachine(bundle: saved, cpus: 4, memoryInBytes: memory << 30)
            var clock = ContinuousClock.now
            try await cold.start()
            let coldAgent = GuestAgent(virtualMachine: cold)
            _ = try await coldAgent.waitUntilReady(timeout: .seconds(timeout))
            print("cold boot: agent answered after \(ContinuousClock.now - clock)")
            // Something written after the boot, which a consistent restore finds again.
            _ = try await coldAgent.run(shell("echo saved > /Users/Shared/state-probe && sync"), timeout: .seconds(30))
            await coldAgent.close()
            clock = ContinuousClock.now
            try await cold.saveState(to: state)
            let size = (try? state.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            print("save: \(ContinuousClock.now - clock), state file \(ByteCountFormatter().string(fromByteCount: Int64(size)))")
            try await cold.forceStop()

            await restore(state, into: saved, label: "restore on the saved instance itself")
            guard !direct else {
                return
            }

            // The overlay as it was at the save, an APFS clone on the same volume.
            let clone = work.appendingPathComponent("clone")
            try FileManager.default.copyItem(at: saved.url, to: clone)
            await restore(state, into: try MacOSVMBundle(url: clone), label: "restore on the overlay of the save")

            let fresh = try base.instance(at: work.appendingPathComponent("fresh"))
            try FileManager.default.removeItem(at: fresh.machineIdentifierURL)
            try FileManager.default.copyItem(at: saved.machineIdentifierURL, to: fresh.machineIdentifierURL)
            await restore(state, into: fresh, label: "restore on a fresh overlay")

            let other = work.appendingPathComponent("other")
            try FileManager.default.copyItem(at: saved.url, to: other)
            let otherBundle = try MacOSVMBundle(url: other)
            try VZMacMachineIdentifier().dataRepresentation.write(to: otherBundle.machineIdentifierURL)
            await restore(state, into: otherBundle, label: "restore with another machine identifier")
        }

        /// Restores `state` into `instance`, reports the time until the agent answers and whether
        /// the file written before the save is there, and stops the guest.
        private func restore(_ state: URL, into instance: MacOSVMBundle, label: String) async {
            do {
                let virtualMachine = try MacOSVirtualMachine(bundle: instance, cpus: 4, memoryInBytes: memory << 30)
                let clock = ContinuousClock.now
                try await virtualMachine.restoreState(from: state)
                let resumed = ContinuousClock.now - clock
                let agent = GuestAgent(virtualMachine: virtualMachine)
                do {
                    _ = try await agent.waitUntilReady(timeout: .seconds(60))
                    let answered = ContinuousClock.now - clock
                    let found = try await agent.run(shell("grep -q saved /Users/Shared/state-probe"), timeout: .seconds(30))
                    let written = try await agent.run(shell("echo after > /Users/Shared/after && sync && grep -q after /Users/Shared/after"), timeout: .seconds(30))
                    let fsck = try await agent.run(shell("diskutil verifyVolume / >/dev/null 2>&1"), timeout: .seconds(300))
                    print(
                        "\(label): resumed after \(resumed), agent answered after \(answered); file from before the save "
                            + "\(found == 0 ? "found" : "missing"), new write \(written == 0 ? "ok" : "failed"), volume check exit \(fsck)")
                } catch {
                    print("\(label): resumed after \(resumed), but \(error)")
                }
                await agent.close()
                try? await virtualMachine.forceStop()
            } catch {
                print("\(label): failed: \(error)")
            }
        }

        private func shell(_ command: String) -> ContainerizationOCI.Process {
            ContainerizationOCI.Process(args: ["/bin/sh", "-c", command], user: User(username: "root"))
        }
    }
}
