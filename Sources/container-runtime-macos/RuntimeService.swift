// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import ParbakeVersion
import RuntimeMacOS

/// Serves the runtime XPC routes for one macOS container.
///
/// The init process of the container is the guest itself: starting it boots the
/// virtual machine, and it exits when the virtual machine stops. Every other process runs in the
/// guest through the guest agent.
actor RuntimeService {
    /// The container label that names the installed macOS VM bundle to boot.
    static let bundleLabel = "runtime-macos.bundle"
    /// The container label that decides what happens when the instance's overlay no longer stacks
    /// on the bundle's disk image: `fail` (default) or `discard`.
    static let incompatibleOverlayLabel = "runtime-macos.on-incompatible-overlay"

    enum IncompatibleOverlayPolicy: String {
        case fail
        case discard
    }
    /// The container label that sets how many seconds the start waits for the guest agent after the boot.
    static let readinessTimeoutLabel = "runtime-macos.readiness-timeout"
    static let defaultReadinessTimeout: Duration = .seconds(180)
    /// How long `shutdown` started through the guest agent gets to report its exit.
    static let agentShutdownTimeout: Duration = .seconds(15)
    /// The directory in the container root that holds the container's instance of the bundle.
    static let vmDirectoryName = "vm"
    /// The least time a guest gets to finish a shutdown it accepted over SSH.
    static let minimumShutdownTimeout: Duration = .seconds(60)
    /// The longest a shutdown over SSH may take before ssh is terminated.
    static let maximumSSHShutdownTimeout: Duration = .seconds(60)

    /// Where the container is in its life.
    ///
    /// `prepared` becomes `starting` when the first start of the init process boots the guest; `starting`
    /// becomes `running` when the boot returns, or `stopping` and then `stopped` when a stop force-stops the
    /// guest first, whether or not the forced stop succeeds.
    enum State {
        case created
        case prepared
        case starting
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
    private var virtualMachine: (any GuestMachine)?
    private var bundle: MacOSVMBundle?
    private var readinessTimeout = defaultReadinessTimeout
    private let environment: RuntimeEnvironment
    /// Runs every process but the init process in the guest; set when the guest is prepared.
    private var agent: (any GuestAgentClient)?
    /// The guest's address on the container network, held until `shutdown`.
    private var network: AllocatedNetwork?
    private var startedDate: Date?
    /// The shutdown requests over SSH in flight, so a forced stop can end them.
    private var shellRequests: [Int: Task<GuestShell.Result, Never>] = [:]
    private var nextShellRequest = 0
    /// Whether a SIGKILL stopped the guest forcibly; a shutdown request that ends after it has nothing left to do.
    private var forceStopRequested = false

    /// The container's state, for tests; the `state` route reports less.
    var currentState: State { state }

    init(root: URL, connection: xpc_connection_t, log: Logger, environment: RuntimeEnvironment) {
        self.root = root
        self.connection = connection
        self.log = log
        self.environment = environment
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

        let runtimeConfiguration = try environment.loadConfiguration(root)
        guard let configuration = runtimeConfiguration.containerConfiguration else {
            throw ContainerizationError(.invalidArgument, message: "runtime configuration is missing the container configuration")
        }
        if let refusal = RuntimeLifecycle.unsupportedInputs(
            mounts: configuration.mounts.count,
            publishedPorts: configuration.publishedPorts.count,
            publishedSockets: configuration.publishedSockets.count
        ) {
            throw ContainerizationError(.unsupported, message: refusal)
        }
        guard let source = configuration.labels[Self.bundleLabel] else {
            throw ContainerizationError(
                .invalidArgument,
                message: "set --label \(Self.bundleLabel)=<path> to the macOS VM bundle to boot"
            )
        }

        let policyValue = configuration.labels[Self.incompatibleOverlayLabel] ?? IncompatibleOverlayPolicy.fail.rawValue
        guard let policy = IncompatibleOverlayPolicy(rawValue: policyValue) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "\(Self.incompatibleOverlayLabel) must be fail or discard, got \(policyValue)"
            )
        }

        var readinessTimeout = Self.defaultReadinessTimeout
        if let value = configuration.labels[Self.readinessTimeoutLabel] {
            guard let seconds = Int(value), seconds > 0 else {
                throw ContainerizationError(
                    .invalidArgument, message: "\(Self.readinessTimeoutLabel) must be a number of seconds, got \(value)")
            }
            readinessTimeout = .seconds(seconds)
        }

        let vmDirectory = root.appendingPathComponent(Self.vmDirectoryName)
        let sourceURL: URL
        var bundle: MacOSVMBundle
        do {
            sourceURL = try environment.validateBundlePath(source)
            bundle = try environment.openInstance(sourceURL, vmDirectory, false)
        } catch {
            throw RuntimeLifecycle.containerizationError(from: error)
        }

        let network: AllocatedNetwork?
        do {
            network = try await environment.allocateNetwork(message, configuration)
        } catch {
            throw RuntimeLifecycle.containerizationError(from: error)
        }
        if let network {
            let attachment = network.attachment
            log.info(
                "allocated guest address",
                metadata: ["network": "\(attachment.network)", "address": "\(attachment.ipv4Address)", "mac": "\(attachment.macAddress?.description ?? "random")"])
        }
        let guest: (machine: any GuestMachine, agent: any GuestAgentClient)
        do {
            do {
                guest = try environment.makeGuest(
                    bundle, configuration.resources.cpus, configuration.resources.memoryInBytes, network)
            } catch let failure as RuntimeFailure {
                guard case .incompatibleOverlay(_, _, let reason) = failure else { throw failure }
                guard policy == .discard else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "\(failure); set --label \(Self.incompatibleOverlayLabel)=discard to start the instance over"
                    )
                }
                log.warning("discarding the instance's overlay, it no longer stacks on the bundle", metadata: ["reason": "\(reason)"])
                bundle = try environment.openInstance(sourceURL, vmDirectory, true)
                guest = try environment.makeGuest(
                    bundle, configuration.resources.cpus, configuration.resources.memoryInBytes, network)
            }
        } catch {
            if let network {
                await environment.releaseNetwork(network)
            }
            throw RuntimeLifecycle.containerizationError(from: error)
        }
        self.configuration = configuration
        self.virtualMachine = guest.machine
        self.agent = guest.agent
        self.network = network
        self.bundle = bundle
        self.readinessTimeout = readinessTimeout
        self.state = .prepared
        log.info("prepared macOS guest", metadata: ["bundle": "\(bundle.url.path)", "source": "\(sourceURL.path)"])
        return message.reply()
    }

    /// Boots the guest when `id` names the init process, and starts the process through the guest
    /// agent otherwise.
    ///
    /// With a bundle that has an agent, the start replies once the agent answers, so a caller
    /// can run processes as soon as `container run -d` returns; a guest whose agent does not answer
    /// within the readiness timeout is stopped and the start fails.
    @Sendable
    func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let (configuration, virtualMachine) = try prepared()
        guard id == configuration.id else {
            let pid = try await converting { try await runningAgent().startProcess(id: id) }
            log.info("started process through the guest agent", metadata: ["id": "\(id)", "pid": "\(pid)"])
            return message.reply()
        }
        guard state == .prepared else {
            let current = state == .starting ? "already starting" : "\(state)"
            throw ContainerizationError(.invalidState, message: "cannot start: container is \(current)")
        }
        state = .starting

        do {
            try await virtualMachine.start()
        } catch {
            guard state == .starting else {
                if state == .stopping { state = .stopped }
                throw Self.stoppedWhileStarting
            }
            state = .prepared
            throw RuntimeLifecycle.containerizationError(from: error)
        }
        guard state == .starting else {
            await abandonStart(virtualMachine)
            throw Self.stoppedWhileStarting
        }
        state = .running
        startedDate = environment.now()
        log.info("started macOS guest")

        Task {
            let exit = await virtualMachine.wait()
            await self.guestStopped(exit)
        }

        if let installed = bundle?.agentVersion, let agent {
            do {
                let version = try await agent.waitUntilReady(timeout: readinessTimeout)
                log.info("guest agent is ready", metadata: ["version": "\(version)", "installed": "\(installed)"])
                if AgentVersionLine(version)?.release != Parbake.release {
                    log.warning(
                        "the guest agent's release differs from this runtime's; run `parbake agent install` to update the bundle's agent",
                        metadata: ["version": "\(version)", "installed": "\(installed)", "release": "\(Parbake.release)"])
                }
            } catch RuntimeFailure.agentTimeout(let seconds, label: nil) {
                log.error("guest agent is not ready, stopping the guest", metadata: ["seconds": "\(seconds)"])
                try? await virtualMachine.forceStop()
                throw RuntimeLifecycle.containerizationError(
                    from: RuntimeFailure.agentTimeout(seconds: seconds, label: Self.readinessTimeoutLabel))
            } catch {
                log.error("guest agent is not ready, stopping the guest", metadata: ["error": "\(error)"])
                try? await virtualMachine.forceStop()
                throw ContainerizationError(.timeout, message: "the macOS guest started but its agent is not ready: \(error)")
            }
        }
        guard state == .running else {
            throw Self.stoppedWhileStarting
        }
        return message.reply()
    }

    /// What a start reports when a stop took the container out of its start.
    private static let stoppedWhileStarting = ContainerizationError(
        .interrupted, message: "the container was stopped while it started")

    /// Ends a boot that returned after a stop arrived: stops a guest that still runs forcibly and closes the agent.
    private func abandonStart(_ virtualMachine: any GuestMachine) async {
        var gone = true
        if virtualMachine.currentExit == nil {
            do {
                try await virtualMachine.forceStop()
            } catch {
                gone = false
                log.error("could not stop the guest that booted after its stop", metadata: ["error": "\(error)"])
            }
        }
        if gone, state == .stopping { state = .stopped }
        await agent?.close()
    }

    /// Creates a process in the guest through the guest agent.
    @Sendable
    func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let process = try Self.ociProcess(message.processConfiguration(), provisionedUsername: bundle?.provisionedUsername)
        let stdio = message.stdio()
        try await converting { try await runningAgent().createProcess(id: id, process: process, stdio: stdio) }
        let user = process.user.username.isEmpty ? "uid \(process.user.uid)" : process.user.username
        log.info("created process through the guest agent", metadata: ["id": "\(id)", "user": "\(user)"])
        return message.reply()
    }

    /// The OCI process the agent starts for `configuration`.
    static func ociProcess(_ configuration: ProcessConfiguration, provisionedUsername: String?) -> ContainerizationOCI.Process {
        let user: GuestUser =
            switch configuration.user {
            case .raw(let name): .name(name)
            case .id(let uid, let gid): .id(uid: uid, gid: gid)
            }
        return ContainerizationOCI.Process(
            args: [configuration.executable] + configuration.arguments,
            cwd: configuration.workingDirectory,
            env: configuration.environment,
            user: user.ociUser(provisionedUsername: provisionedUsername, additionalGids: configuration.supplementalGroups),
            terminal: configuration.terminal
        )
    }

    @Sendable
    func state(_ message: XPCMessage) async throws -> XPCMessage {
        var status: RuntimeStatus
        var containers: [ContainerSnapshot] = []
        switch state {
        case .created, .prepared, .starting, .stopped, .shuttingDown:
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
        try reply.setRuntimeSnapshot(SandboxSnapshot(status: status, networks: network.map { [$0.attachment] } ?? [], containers: containers))
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
            if state == .stopping {
                state = .stopped
            }
        case .starting:
            let (_, virtualMachine) = try prepared()
            state = .stopping
            log.info("stopping the guest while it starts")
            do {
                try await virtualMachine.forceStop()
            } catch {
                // The container stays `.stopping`: the guest may still run. The start force-stops it again
                // once its boot returns.
                log.error("could not stop the guest while it starts", metadata: ["error": "\(error)"])
                throw RuntimeLifecycle.containerizationError(from: error)
            }
            if state == .stopping {
                state = .stopped
            }
        case .prepared:
            state = .stopped
        default:
            break
        }
        return message.reply()
    }

    /// Sends a signal to a process through the guest agent; for the init process, stops the guest
    /// forcibly on SIGKILL, also while a stop runs, and shuts it down on SIGTERM, SIGINT or SIGQUIT.
    /// A missing signal counts as SIGTERM.
    @Sendable
    func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let signal = message.string(key: RuntimeKeys.signal.rawValue) ?? ""
        let (configuration, virtualMachine) = try prepared()
        guard id == configuration.id else {
            guard let number = GuestAgent.signalNumber(signal) else {
                throw ContainerizationError(.invalidArgument, message: "unknown signal \(signal)")
            }
            try await converting { try await runningAgent().signal(id: id, signal: number) }
            return message.reply()
        }
        let isRunning = state == .running
        let isStopping = state == .stopping
        let number = signal.isEmpty ? SIGTERM : GuestAgent.signalNumber(signal)

        switch RuntimeLifecycle.initSignalAction(signal: number, name: signal, isRunning: isRunning, isStopping: isStopping) {
        case .forceStop:
            forceStopRequested = true
            for request in shellRequests.values { request.cancel() }
            try await virtualMachine.forceStop()
        case .shutDown:
            if await !shutDown(virtualMachine, timeout: Self.maximumSSHShutdownTimeout), state == .running || state == .stopping {
                try await virtualMachine.requestStop()
            }
        case .alreadyStopping:
            break
        case .refuse(let reason):
            throw ContainerizationError(RuntimeLifecycle.refusalCode(isRunning: isRunning, isStopping: isStopping), message: reason)
        }
        return message.reply()
    }

    /// Resizes the terminal of a process in the guest; the init process has no terminal.
    @Sendable
    func resize(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let (configuration, _) = try prepared()
        guard id != configuration.id else {
            return message.reply()
        }
        let columns = UInt32(clamping: message.uint64(key: RuntimeKeys.width.rawValue))
        let rows = UInt32(clamping: message.uint64(key: RuntimeKeys.height.rawValue))
        try await converting { try await runningAgent().resize(id: id, columns: columns, rows: rows) }
        return message.reply()
    }

    /// Waits until a process exits, or the guest stops for the init process, and returns its exit.
    @Sendable
    func wait(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let (configuration, virtualMachine) = try prepared()
        let exit: GuestExit
        if id == configuration.id {
            exit = await virtualMachine.wait()
        } else {
            exit = try await processExit(id: id, virtualMachine: virtualMachine)
        }
        let reply = message.reply()
        reply.set(key: RuntimeKeys.exitCode.rawValue, value: Int64(exit.exitCode))
        reply.set(key: RuntimeKeys.exitedAt.rawValue, value: exit.exitedAt)
        return reply
    }

    /// Returns the exit of a process run through the agent. When the agent's stream for the
    /// process ends, the wait gives the guest `RuntimeLifecycle.guestLossTimeout` to stop and fails
    /// with `.interrupted`, so the caller cannot take it for the process's own exit code.
    private func processExit(id: String, virtualMachine: any GuestMachine) async throws -> GuestExit {
        do {
            return try await runningAgent().wait(id: id)
        } catch RuntimeFailure.processLost {
            let guest = await virtualMachine.wait(timeout: RuntimeLifecycle.guestLossTimeout)
            throw ContainerizationError(
                .interrupted, message: RuntimeLifecycle.lostProcessMessage(processID: id, guestExitCode: guest?.exitCode))
        } catch {
            throw RuntimeLifecycle.containerizationError(from: error)
        }
    }

    @Sendable
    func shutdown(_ message: XPCMessage) async throws -> XPCMessage {
        switch state {
        case .created, .prepared, .stopped, .stopping:
            state = .shuttingDown
            await agent?.close()
            agent = nil
            await releaseNetwork()
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

    private func releaseNetwork() async {
        guard let network else {
            return
        }
        self.network = nil
        await environment.releaseNetwork(network)
    }

    /// Runs `body` and reports a `RuntimeFailure` it throws as the `ContainerizationError` the client decodes.
    private func converting<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw RuntimeLifecycle.containerizationError(from: error)
        }
    }

    private func runningAgent() throws -> any GuestAgentClient {
        guard state == .running, let agent else {
            throw ContainerizationError(.invalidState, message: "container is not running")
        }
        return agent
    }

    private func prepared() throws -> (ContainerConfiguration, any GuestMachine) {
        guard let configuration, let virtualMachine else {
            throw ContainerizationError(.invalidState, message: "container is not bootstrapped")
        }
        return (configuration, virtualMachine)
    }

    /// Shuts the guest down through the agent or over SSH, or presses the power button when neither is
    /// available, and stops it forcibly once the waits pass.
    ///
    /// A shutdown the guest accepted gets at least `minimumShutdownTimeout`. The request itself gets
    /// `min(timeout, maximumSSHShutdownTimeout)`: `container stop` passes 5 s by default, so the request
    /// ends after 5 s, and a stop timeout too short for the request falls back to the power button
    /// before the guest is stopped forcibly.
    ///
    /// Throws the error of a failed forced stop and leaves the container `.stopping`: the guest may still run.
    private func stopGuest(_ virtualMachine: any GuestMachine, timeout: Duration) async throws {
        var forceStopFailure: (any Error)?
        let requestTimeout = min(timeout, Self.maximumSSHShutdownTimeout)
        let outcome = await GuestShutdown.run(
            virtualMachine,
            request: { @Sendable [self] in await shutDown(virtualMachine, timeout: requestTimeout) },
            requestWait: max(timeout, Self.minimumShutdownTimeout),
            powerButtonWait: timeout,
            note: { [log] step, error in
                switch step {
                case .requestStop: log.warning("guest rejected the stop request", metadata: ["error": "\(error)"])
                case .forceStop:
                    forceStopFailure = error
                    log.error("could not stop the guest forcibly", metadata: ["error": "\(error)"])
                }
            })
        if let forceStopFailure {
            throw RuntimeLifecycle.containerizationError(from: forceStopFailure)
        }
        if outcome == .forced {
            log.info("guest did not shut down in time, stopped it forcibly")
        }
    }

    /// Asks the guest to shut down through the agent, then over SSH; returns whether the guest
    /// accepted. The SSH attempt ends after `timeout`.
    private func shutDown(_ virtualMachine: any GuestMachine, timeout: Duration) async -> Bool {
        if await shutDownThroughAgent() {
            return true
        }
        return await shutDownOverSSH(virtualMachine, timeout: timeout)
    }

    /// Runs the guest's shutdown as root through the agent, or with the provisioned account's
    /// passwordless sudo rule when the agent does not run as root; returns whether the guest
    /// accepted it.
    private func shutDownThroughAgent() async -> Bool {
        guard let agent else {
            return false
        }
        let log = self.log
        return await agent.shutDown(provisionedUsername: bundle?.provisionedUsername, timeout: Self.agentShutdownTimeout) {
            log.info("\($0)")
        }
    }

    /// Runs the shutdown in the guest with the provisioned account and the guest key;
    /// returns whether the guest accepted it, or true when the guest stopped meanwhile.
    ///
    /// The shell runs off the actor, so the other routes stay answerable while it runs; ssh is
    /// terminated after `timeout`, or when a forced stop cancels the request.
    private func shutDownOverSSH(_ virtualMachine: any GuestMachine, timeout: Duration) async -> Bool {
        if forceStopRequested || virtualMachine.currentExit != nil {
            log.info("guest stopped before the shutdown over SSH began")
            return true
        }
        guard let shell = bundle?.guestShell else {
            log.info("bundle has no guest key, asking the guest to shut down")
            return false
        }
        guard let address = network.map({ $0.attachment.ipv4Address.address.description }) ?? environment.leaseAddress(virtualMachine.macAddress) else {
            log.warning("guest has no DHCP lease, asking it to shut down")
            return false
        }
        // The command reports the acceptance before it shuts down, because the shutdown ends sshd.
        let result = await runShellRequest(shell, GuestCommands.shutdownIfAllowed, address, timeout)
        let guestGone = forceStopRequested || virtualMachine.currentExit != nil || (state != .running && state != .stopping)
        guard !guestGone else {
            log.info("guest stopped while the shutdown over SSH ran")
            return true
        }
        guard result.output.contains(GuestCommands.acceptedMarker) else {
            log.warning(
                "guest refused the shutdown over SSH",
                metadata: [
                    "address": "\(address)", "status": "\(result.status)", "timedOut": "\(result.timedOut)",
                    "error": "\(LogText.sanitized(result.errorOutput))",
                ])
            return false
        }
        log.info("guest accepted the shutdown over SSH", metadata: ["address": "\(address)"])
        return true
    }

    /// Runs `command` in its own task, which a forced stop cancels, and returns what the shell reported.
    private func runShellRequest(_ shell: GuestShell, _ command: String, _ address: String, _ timeout: Duration) async -> GuestShell.Result {
        let environment = self.environment
        let request = Task { await environment.runShell(shell, command, address, timeout) }
        nextShellRequest += 1
        let id = nextShellRequest
        shellRequests[id] = request
        let result = await request.value
        shellRequests[id] = nil
        return result
    }

    private func guestStopped(_ exit: GuestExit) async {
        log.info("macOS guest stopped", metadata: ["exitCode": "\(exit.exitCode)"])
        await agent?.close()
        if state == .running || state == .stopping {
            state = .stopped
        }
    }
}
