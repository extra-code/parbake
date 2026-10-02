// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import Foundation
import Logging
import RuntimeMacOS

/// Serves the runtime XPC routes for one macOS container.
///
/// The init process of the container is the guest itself: starting it boots the
/// virtual machine, and it exits when the virtual machine stops.
actor RuntimeService {
    /// The container label that names the installed macOS VM bundle to boot.
    static let bundleLabel = "runtime-macos.bundle"
    /// The directory in the container root that holds the container's clone of the bundle.
    static let vmDirectoryName = "vm"

    enum State {
        case created
        case prepared
        case running
        case stopping
        case stopped
        case shuttingDown
    }

    private let root: URL
    private let connection: xpc_connection_t
    private let log: Logger
    private var state: State = .created
    private var configuration: ContainerConfiguration?
    private var virtualMachine: MacOSVirtualMachine?
    private var startedDate: Date?

    init(root: URL, connection: xpc_connection_t, log: Logger) {
        self.root = root
        self.connection = connection
        self.log = log
    }

    /// Returns an endpoint for the anonymous connection that serves all other routes.
    @Sendable
    func createEndpoint(_ message: XPCMessage) async throws -> XPCMessage {
        let endpoint = xpc_endpoint_create(self.connection)
        let reply = message.reply()
        reply.set(key: RuntimeKeys.runtimeServiceEndpoint.rawValue, value: endpoint)
        return reply
    }

    /// Clones the VM bundle named by `bundleLabel` into the container root and prepares the guest.
    @Sendable
    func bootstrap(_ message: XPCMessage) async throws -> XPCMessage {
        guard state == .created else {
            throw ContainerizationError(.invalidState, message: "container expected to be in created state, got: \(state)")
        }

        let runtimeConfiguration = try RuntimeConfiguration.readRuntimeConfiguration(from: root)
        guard let configuration = runtimeConfiguration.containerConfiguration else {
            throw ContainerizationError(.invalidArgument, message: "runtime configuration is missing the container configuration")
        }
        guard let source = configuration.labels[Self.bundleLabel] else {
            throw ContainerizationError(
                .invalidArgument,
                message: "set --label \(Self.bundleLabel)=<path> to the macOS VM bundle to boot"
            )
        }

        let vmDirectory = root.appendingPathComponent(Self.vmDirectoryName)
        let bundle =
            FileManager.default.fileExists(atPath: vmDirectory.path)
            ? try MacOSVMBundle(url: vmDirectory)
            : try MacOSVMBundle(url: URL(fileURLWithPath: source)).clone(to: vmDirectory)

        let virtualMachine = try MacOSVirtualMachine(
            bundle: bundle,
            cpus: configuration.resources.cpus,
            memoryInBytes: configuration.resources.memoryInBytes
        )
        self.configuration = configuration
        self.virtualMachine = virtualMachine
        self.state = .prepared
        log.info("prepared macOS guest", metadata: ["bundle": "\(bundle.url.path)", "source": "\(source)"])
        return message.reply()
    }

    /// Boots the guest when `id` names the init process.
    @Sendable
    func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let (configuration, virtualMachine) = try prepared()
        guard id == configuration.id else {
            throw ContainerizationError(.unsupported, message: "processes other than the init process need the guest agent")
        }
        guard state == .prepared else {
            throw ContainerizationError(.invalidState, message: "cannot start: container is \(state)")
        }

        try await virtualMachine.start()
        state = .running
        startedDate = Date()
        log.info("started macOS guest")

        Task {
            let exit = await virtualMachine.wait()
            self.guestStopped(exit)
        }
        return message.reply()
    }

    @Sendable
    func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        throw ContainerizationError(.unsupported, message: "processes other than the init process need the guest agent")
    }

    @Sendable
    func state(_ message: XPCMessage) async throws -> XPCMessage {
        var status: RuntimeStatus
        var containers: [ContainerSnapshot] = []
        switch state {
        case .created, .prepared, .stopped, .shuttingDown:
            status = .stopped
        case .stopping:
            status = .stopping
        case .running:
            status = .running
            if let configuration {
                containers = [ContainerSnapshot(configuration: configuration, status: .running, networks: [], startedDate: startedDate)]
            }
        }

        let reply = message.reply()
        try reply.setRuntimeSnapshot(SandboxSnapshot(status: status, networks: [], containers: containers))
        return reply
    }

    /// Asks the guest to shut down and stops it forcibly once the timeout passes.
    @Sendable
    func stop(_ message: XPCMessage) async throws -> XPCMessage {
        let options = try message.runtimeStopOptions()
        switch state {
        case .running:
            let (_, virtualMachine) = try prepared()
            state = .stopping
            try await stopGuest(virtualMachine, timeout: .seconds(Int64(options.timeoutInSeconds)))
            state = .stopped
        case .prepared:
            state = .stopped
        default:
            break
        }
        return message.reply()
    }

    /// Stops the guest forcibly on SIGKILL and asks it to shut down on any other signal.
    @Sendable
    func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let signal = message.string(key: RuntimeKeys.signal.rawValue) ?? ""
        let (configuration, virtualMachine) = try prepared()
        guard id == configuration.id else {
            throw ContainerizationError(.notFound, message: "process \(id) does not exist")
        }
        guard state == .running else {
            throw ContainerizationError(.invalidState, message: "cannot kill: container is not running")
        }

        if Self.isKill(signal) {
            try await virtualMachine.forceStop()
        } else {
            try await virtualMachine.requestStop()
        }
        return message.reply()
    }

    /// Accepts terminal resizes and ignores them, because the guest has no terminal attached.
    @Sendable
    func resize(_ message: XPCMessage) async throws -> XPCMessage {
        message.reply()
    }

    /// Waits until the guest stops and returns its exit.
    @Sendable
    func wait(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let (configuration, virtualMachine) = try prepared()
        guard id == configuration.id else {
            throw ContainerizationError(.notFound, message: "process \(id) does not exist")
        }

        let exit = await virtualMachine.wait()
        let reply = message.reply()
        reply.set(key: RuntimeKeys.exitCode.rawValue, value: Int64(exit.exitCode))
        reply.set(key: RuntimeKeys.exitedAt.rawValue, value: exit.exitedAt)
        return reply
    }

    @Sendable
    func shutdown(_ message: XPCMessage) async throws -> XPCMessage {
        switch state {
        case .created, .prepared, .stopped, .stopping:
            state = .shuttingDown
        default:
            throw ContainerizationError(.invalidState, message: "cannot shutdown: container is not stopped")
        }
        return message.reply()
    }

    /// Rejects routes that need the guest agent or are not implemented yet.
    @Sendable
    func unsupported(_ message: XPCMessage) async throws -> XPCMessage {
        throw ContainerizationError(.unsupported, message: "container-runtime-macos does not support this operation yet")
    }

    private func prepared() throws -> (ContainerConfiguration, MacOSVirtualMachine) {
        guard let configuration, let virtualMachine else {
            throw ContainerizationError(.invalidState, message: "container is not bootstrapped")
        }
        return (configuration, virtualMachine)
    }

    private func stopGuest(_ virtualMachine: MacOSVirtualMachine, timeout: Duration) async throws {
        do {
            try await virtualMachine.requestStop()
        } catch {
            log.warning("guest rejected the stop request", metadata: ["error": "\(error)"])
        }
        if await virtualMachine.wait(timeout: timeout) == nil {
            log.info("guest did not shut down in time, stopping it")
            try await virtualMachine.forceStop()
        }
    }

    private func guestStopped(_ exit: GuestExit) {
        log.info("macOS guest stopped", metadata: ["exitCode": "\(exit.exitCode)"])
        if state == .running || state == .stopping {
            state = .stopped
        }
    }

    static func isKill(_ signal: String) -> Bool {
        ["SIGKILL", "KILL", "9"].contains(signal.uppercased())
    }
}
