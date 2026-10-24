// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationOCI
import Foundation
import Logging

@testable import RuntimeMacOS
@testable import container_runtime_macos

/// A `RuntimeEnvironment` whose pieces are fakes, with the knobs and records a route test needs.
///
/// The environment hands out one `machine` and one `agent`, a bundle directory of placeholder files
/// that `MacOSVMBundle` accepts, and a configuration with the bundle label set. Call `cleanUp()` when the test ends.
final class FakeRuntimeEnvironment: @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case loadConfiguration
        case validateBundlePath(String)
        case openInstance(bundle: URL, instance: URL, resetOverlay: Bool)
        case makeGuest(cpus: Int, memory: UInt64, hasNetwork: Bool)
        case runShell(command: String, address: String, timeout: Duration)
        case allocateNetwork
        case releaseNetwork
        case leaseAddress(String)
    }

    /// The id of the container the fake configuration describes.
    static let containerID = "fake-container"

    let machine: FakeGuestMachine
    let agent: FakeGuestAgentClient
    /// The directory `openInstance` opens, whatever instance and bundle it is asked for.
    let bundleDirectory: URL
    /// The anonymous connection the service hands out endpoints for; libxpc traps on releasing it unresumed.
    private let connection: xpc_connection_t

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var configuration: ContainerConfiguration
    private var pathError: (any Error)?
    private var guestErrors: [any Error] = []
    private var shellHandler: @Sendable (_ command: String) async -> GuestShell.Result
    private var network: AllocatedNetwork?
    private var allocationError: (any Error)?
    private var leases: [String: String] = [:]
    private var date = Date(timeIntervalSince1970: 1_000_000)

    /// `labels` are added to the container configuration; the bundle label names a placeholder path.
    init(
        labels: [String: String] = [:], machine: FakeGuestMachine = FakeGuestMachine(),
        agent: FakeGuestAgentClient = FakeGuestAgentClient()
    ) throws {
        self.machine = machine
        self.agent = agent
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in MacOSVMBundle.fileNames {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        self.bundleDirectory = directory
        self.connection = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        let image = ImageDescription(
            reference: "fake", descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0))
        var configuration = ContainerConfiguration(
            id: Self.containerID, image: image, process: ProcessConfiguration(executable: "/bin/true", arguments: [], environment: []))
        configuration.labels = [RuntimeService.bundleLabel: "/fake/bundle"].merging(labels) { _, new in new }
        self.configuration = configuration
        self.shellHandler = { _ in GuestShell.Result(status: 0, output: "\(GuestCommands.acceptedMarker)\n", errorOutput: "") }
    }

    func cleanUp() {
        xpc_connection_cancel(connection)
        try? FileManager.default.removeItem(at: bundleDirectory)
    }

    /// Gives the bundle an installed guest agent that reports `version`, so a start waits for the agent.
    func installAgent(version: String = "1 0.0.0-dev") throws {
        try Data(version.utf8).write(to: bundleDirectory.appendingPathComponent(MacOSVMBundle.agentName))
    }

    /// Gives the bundle a provisioned account and a guest key, so a stop can shut the guest down over SSH.
    func provisionGuest(username: String = "builder") throws {
        try Data(username.utf8).write(to: bundleDirectory.appendingPathComponent(MacOSVMBundle.provisionedName))
        try Data("key".utf8).write(to: bundleDirectory.appendingPathComponent(MacOSVMBundle.guestKeyName))
    }

    /// Arranges for a stop to shut the guest down over SSH and returns the gate that holds that shell.
    ///
    /// The agent refuses the shutdown, the bundle gets an account and a key, the guest a lease, and the
    /// shell waits on the gate before it accepts.
    func suspendShellShutdown() async throws -> Gate {
        try provisionGuest()
        setLease("192.168.64.9", for: machine.macAddress)
        await agent.configure(acceptsShutdown: false)
        let gate = Gate()
        answerShell { _ in
            try? await gate.pass()
            return GuestShell.Result(status: 0, output: "\(GuestCommands.acceptedMarker)\n", errorOutput: "")
        }
        return gate
    }

    /// Like `suspendShellShutdown()`, but the shell holds until its task is cancelled and then reports a refusal.
    ///
    /// Returns the gate the shell waits on, and a gate that has one arrival once the shell saw the cancellation.
    func holdShellUntilCancelled() async throws -> (held: Gate, cancelled: Gate) {
        try provisionGuest()
        setLease("192.168.64.9", for: machine.macAddress)
        await agent.configure(acceptsShutdown: false)
        let held = Gate()
        let cancelled = Gate()
        cancelled.open()
        answerShell { _ in
            do {
                try await held.pass()
            } catch {
                try? await cancelled.pass()
            }
            return GuestShell.Result(status: 143, output: "", errorOutput: "")
        }
        return (held, cancelled)
    }

    /// The calls the service made to the environment, in order.
    var calls: [Call] { lock.withLock { recorded } }

    /// Changes the container configuration `loadConfiguration` returns.
    func configure(_ change: (inout ContainerConfiguration) -> Void) {
        lock.withLock { change(&configuration) }
    }

    /// Makes `validateBundlePath` throw `error`.
    func failBundlePath(with error: any Error) { lock.withLock { pathError = error } }

    /// Makes the next `makeGuest` calls throw these errors, one each, before it succeeds.
    func failMakeGuest(with errors: [any Error]) { lock.withLock { guestErrors = errors } }

    /// Answers every `runShell` call with `handler(command)`; the handler may suspend.
    func answerShell(_ handler: @escaping @Sendable (_ command: String) async -> GuestShell.Result) {
        lock.withLock { shellHandler = handler }
    }

    /// The network `allocateNetwork` returns; nil (the default) means the container has none.
    func provideNetwork(_ network: AllocatedNetwork?) { lock.withLock { self.network = network } }

    /// Makes `allocateNetwork` throw `error`.
    func failAllocateNetwork(with error: any Error) { lock.withLock { allocationError = error } }

    /// The address `leaseAddress` reports for `macAddress`.
    func setLease(_ address: String, for macAddress: String) { lock.withLock { leases[macAddress] = address } }

    /// How many times `releaseNetwork` ran.
    var releasedNetworks: Int { calls.filter { $0 == .releaseNetwork }.count }

    private func record(_ call: Call) { lock.withLock { recorded.append(call) } }

    var environment: RuntimeEnvironment {
        RuntimeEnvironment(
            loadConfiguration: { [self] root in
                record(.loadConfiguration)
                let configuration = lock.withLock { self.configuration }
                return RuntimeConfiguration(path: root, initialFilesystem: nil, kernel: nil, containerConfiguration: configuration)
            },
            validateBundlePath: { [self] path in
                record(.validateBundlePath(path))
                if let error = lock.withLock({ pathError }) { throw error }
                return URL(fileURLWithPath: path)
            },
            openInstance: { [self] bundle, instance, resetOverlay in
                record(.openInstance(bundle: bundle, instance: instance, resetOverlay: resetOverlay))
                return try MacOSVMBundle(url: bundleDirectory)
            },
            makeGuest: { [self] _, cpus, memory, network in
                record(.makeGuest(cpus: cpus, memory: memory, hasNetwork: network != nil))
                let error = lock.withLock { guestErrors.isEmpty ? nil : guestErrors.removeFirst() }
                if let error { throw error }
                return (machine, agent)
            },
            runShell: { [self] _, command, address, timeout in
                record(.runShell(command: command, address: address, timeout: timeout))
                return await lock.withLock { shellHandler }(command)
            },
            allocateNetwork: { [self] _, _ in
                record(.allocateNetwork)
                if let error = lock.withLock({ allocationError }) { throw error }
                return lock.withLock { network }
            },
            releaseNetwork: { [self] _ in record(.releaseNetwork) },
            leaseAddress: { [self] macAddress in
                record(.leaseAddress(macAddress))
                return lock.withLock { leases[macAddress] }
            },
            now: { [self] in lock.withLock { date } }
        )
    }

    /// A service for the fake container, rooted at a path the fake never reads, that logs to `log`.
    func makeService(log: Logger = Logger(label: "fake-runtime")) -> RuntimeService {
        RuntimeService(
            root: URL(fileURLWithPath: "/fake/root"),
            connection: connection,
            log: log,
            environment: environment
        )
    }
}
