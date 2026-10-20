// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerNetworkClient
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import RuntimeMacOS
import Virtualization
import vmnet

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
    private var bundle: MacOSVMBundle?
    private var readinessTimeout = defaultReadinessTimeout
    /// Runs every process but the init process in the guest; set when the guest boots.
    private var agent: GuestAgent?
    /// The guest's address on the container network; the open session holds the allocation.
    private var attachment: Attachment?
    private var networkSession: XPCClientSession?
    /// Answers the guest's DHCP requests on the container network, which runs no DHCP server.
    private var dhcpServer: GuestDHCPServer?
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
        let sourceBundle = try MacOSVMBundle(url: URL(fileURLWithPath: source))
        let bundle =
            FileManager.default.fileExists(atPath: vmDirectory.path)
            ? try MacOSVMBundle(url: vmDirectory)
            : try sourceBundle.instance(at: vmDirectory)

        let network = try await allocateNetwork(message, configuration: configuration)
        let virtualMachine: MacOSVirtualMachine
        do {
            do {
                virtualMachine = try MacOSVirtualMachine(
                    bundle: bundle,
                    cpus: configuration.resources.cpus,
                    memoryInBytes: configuration.resources.memoryInBytes,
                    network: network
                )
            } catch let error as MacOSVMBundle.IncompatibleOverlayError {
                guard policy == .discard else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "\(error); set --label \(Self.incompatibleOverlayLabel)=discard to start the instance over"
                    )
                }
                log.warning("discarding the instance's overlay, it no longer stacks on the bundle", metadata: ["reason": "\(error.reason)"])
                try bundle.resetOverlay(from: sourceBundle)
                virtualMachine = try MacOSVirtualMachine(
                    bundle: bundle,
                    cpus: configuration.resources.cpus,
                    memoryInBytes: configuration.resources.memoryInBytes,
                    network: network
                )
            }
        } catch {
            releaseNetwork()
            throw error
        }
        self.configuration = configuration
        self.virtualMachine = virtualMachine
        self.bundle = bundle
        self.readinessTimeout = readinessTimeout
        self.state = .prepared
        log.info("prepared macOS guest", metadata: ["bundle": "\(bundle.url.path)", "source": "\(source)"])
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
            let pid = try await runningAgent().startProcess(id: id)
            log.info("started process through the guest agent", metadata: ["id": "\(id)", "pid": "\(pid)"])
            return message.reply()
        }
        guard state == .prepared else {
            throw ContainerizationError(.invalidState, message: "cannot start: container is \(state)")
        }

        try await virtualMachine.start()
        let agent = GuestAgent(virtualMachine: virtualMachine)
        self.agent = agent
        state = .running
        startedDate = Date()
        log.info("started macOS guest")

        Task {
            let exit = await virtualMachine.wait()
            await self.guestStopped(exit)
        }

        if let installed = bundle?.agentVersion {
            do {
                let version = try await agent.waitUntilReady(timeout: readinessTimeout)
                log.info("guest agent is ready", metadata: ["version": "\(version)", "installed": "\(installed)"])
            } catch {
                log.error("guest agent is not ready, stopping the guest", metadata: ["error": "\(error)"])
                try? await virtualMachine.forceStop()
                throw ContainerizationError(.timeout, message: "the macOS guest started but its agent is not ready: \(error)")
            }
        }
        return message.reply()
    }

    /// Creates a process in the guest through the guest agent.
    @Sendable
    func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let process = try Self.ociProcess(message.processConfiguration(), provisionedUsername: bundle?.provisionedUsername)
        try await runningAgent().createProcess(id: id, process: process, stdio: message.stdio())
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
        try reply.setRuntimeSnapshot(SandboxSnapshot(status: status, networks: attachment.map { [$0] } ?? [], containers: containers))
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

    /// Sends a signal to a process through the guest agent; for the init process, stops the guest
    /// forcibly on SIGKILL and shuts it down on any other signal.
    @Sendable
    func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.id()
        let signal = message.string(key: RuntimeKeys.signal.rawValue) ?? ""
        let (configuration, virtualMachine) = try prepared()
        guard id == configuration.id else {
            guard let number = GuestAgent.signalNumber(signal) else {
                throw ContainerizationError(.invalidArgument, message: "unknown signal \(signal)")
            }
            try await runningAgent().signal(id: id, signal: number)
            return message.reply()
        }
        guard state == .running else {
            throw ContainerizationError(.invalidState, message: "cannot kill: container is not running")
        }

        if Self.isKill(signal) {
            try await virtualMachine.forceStop()
        } else if await !shutDown(virtualMachine) {
            try await virtualMachine.requestStop()
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
        try await runningAgent().resize(id: id, columns: columns, rows: rows)
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
            exit = try await runningAgent().wait(id: id)
        }
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
            await agent?.close()
            agent = nil
            releaseNetwork()
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

    /// Allocates the guest's address on the container's first network and returns that network,
    /// or nil when the container has no network; the guest then uses Virtualization.framework NAT.
    private func allocateNetwork(_ message: XPCMessage, configuration: ContainerConfiguration) async throws -> GuestNetwork? {
        let infos = (try? message.networkBootstrapInfos()) ?? []
        guard let info = infos.first, let attachmentConfiguration = configuration.networks.first else {
            return nil
        }
        let client = NetworkClient(id: attachmentConfiguration.network, plugin: info.plugin)
        let session = client.connect()
        do {
            let (attachment, additionalData) = try await client.allocate(
                hostname: attachmentConfiguration.options.hostname,
                macAddress: attachmentConfiguration.options.macAddress,
                on: session
            )
            guard let additionalData else {
                throw ContainerizationError(.invalidState, message: "network \(attachment.network) returned no vmnet network reference")
            }
            var status: vmnet_return_t = .VMNET_SUCCESS
            guard let reference = vmnet_network_create_with_serialization(additionalData.underlying, &status) else {
                throw ContainerizationError(.invalidState, message: "cannot deserialize the vmnet network reference, status \(status)")
            }
            let macAddress = attachment.macAddress?.description ?? VZMACAddress.randomLocallyAdministered().string
            try startDHCPServer(on: reference, attachment: attachment, macAddress: macAddress, configuration: configuration)
            self.attachment = attachment
            self.networkSession = session
            log.info(
                "allocated guest address",
                metadata: ["network": "\(attachment.network)", "address": "\(attachment.ipv4Address)", "mac": "\(attachment.macAddress?.description ?? "random")"])
            return GuestNetwork(reference: reference, macAddress: macAddress)
        } catch {
            session.close()
            throw error
        }
    }

    /// Starts the DHCP server that gives the guest with `macAddress` the attachment's address,
    /// gateway and DNS servers.
    private func startDHCPServer(
        on network: vmnet_network_ref, attachment: Attachment, macAddress: String, configuration: ContainerConfiguration
    ) throws {
        let nameservers = configuration.dns.flatMap { $0.nameservers.isEmpty ? nil : $0.nameservers } ?? [attachment.ipv4Gateway.description]
        guard let clientMAC = DHCPMessage.mac(macAddress),
            let address = DHCPMessage.ipv4(attachment.ipv4Address.address.description),
            let gateway = DHCPMessage.ipv4(attachment.ipv4Gateway.description)
        else {
            throw ContainerizationError(.invalidArgument, message: "invalid network attachment \(attachment.ipv4Address) via \(attachment.ipv4Gateway)")
        }
        let lease = DHCPMessage.Lease(
            clientMAC: clientMAC,
            address: address,
            subnetMask: DHCPMessage.mask(prefixLength: Int(attachment.ipv4Address.prefix.length)),
            gateway: gateway,
            nameservers: nameservers.compactMap(DHCPMessage.ipv4)
        )
        let log = self.log
        let server = GuestDHCPServer(lease: lease) { request, reply in
            log.info("answered the guest's DHCP request", metadata: ["request": "\(request)", "reply": "\(reply)"])
        }
        try server.start(on: network)
        dhcpServer = server
    }

    private func releaseNetwork() {
        dhcpServer?.stop()
        dhcpServer = nil
        networkSession?.close()
        networkSession = nil
        attachment = nil
    }

    private func runningAgent() throws -> GuestAgent {
        guard state == .running, let agent else {
            throw ContainerizationError(.invalidState, message: "container is not running")
        }
        return agent
    }

    private func prepared() throws -> (ContainerConfiguration, MacOSVirtualMachine) {
        guard let configuration, let virtualMachine else {
            throw ContainerizationError(.invalidState, message: "container is not bootstrapped")
        }
        return (configuration, virtualMachine)
    }

    /// Shuts the guest down through the agent or over SSH, or asks it to shut down like a press of
    /// the power button when neither is available, and stops it forcibly once the timeout passes.
    ///
    /// A shutdown the guest accepted gets at least `minimumShutdownTimeout`.
    private func stopGuest(_ virtualMachine: MacOSVirtualMachine, timeout: Duration) async throws {
        var timeout = timeout
        if await shutDown(virtualMachine) {
            timeout = max(timeout, Self.minimumShutdownTimeout)
        } else {
            do {
                try await virtualMachine.requestStop()
            } catch {
                log.warning("guest rejected the stop request", metadata: ["error": "\(error)"])
            }
        }
        if await virtualMachine.wait(timeout: timeout) == nil {
            log.info("guest did not shut down in time, stopping it")
            try await virtualMachine.forceStop()
        }
    }

    /// Runs `shutdown -h now` in the guest through the agent, then over SSH; returns whether the
    /// guest accepted it.
    private func shutDown(_ virtualMachine: MacOSVirtualMachine) async -> Bool {
        if await shutDownThroughAgent() {
            return true
        }
        return shutDownOverSSH(virtualMachine)
    }

    /// Runs `shutdown -h now` as root through the agent, or with the provisioned account's
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

    /// Runs `shutdown -h now` in the guest with the provisioned account and the guest key;
    /// returns whether the guest accepted it.
    private func shutDownOverSSH(_ virtualMachine: MacOSVirtualMachine) -> Bool {
        guard let shell = bundle?.guestShell else {
            log.info("bundle has no guest key, asking the guest to shut down")
            return false
        }
        guard let address = attachment.map({ $0.ipv4Address.address.description }) ?? DHCPLeases.currentAddress(for: virtualMachine.macAddress) else {
            log.warning("guest has no DHCP lease, asking it to shut down")
            return false
        }
        let accepted = "parbake: shutting down"
        // shutdown ends sshd, so the guest reports the acceptance before it runs shutdown.
        let result = shell.run(
            "sudo -n -l /sbin/shutdown >/dev/null && echo '\(accepted)' && sudo -n /sbin/shutdown -h now >/dev/null",
            on: address)
        guard result.output.contains(accepted) else {
            log.warning(
                "guest refused the shutdown over SSH",
                metadata: [
                    "address": "\(address)", "status": "\(result.status)",
                    "error": "\(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))",
                ])
            return false
        }
        log.info("guest accepted the shutdown over SSH", metadata: ["address": "\(address)"])
        return true
    }

    private func guestStopped(_ exit: GuestExit) async {
        log.info("macOS guest stopped", metadata: ["exitCode": "\(exit.exitCode)"])
        await agent?.close()
        if state == .running || state == .stopping {
            state = .stopped
        }
    }

    static func isKill(_ signal: String) -> Bool {
        ["SIGKILL", "KILL", "9"].contains(signal.uppercased())
    }
}
