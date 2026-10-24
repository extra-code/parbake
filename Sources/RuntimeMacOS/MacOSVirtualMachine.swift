// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Virtualization
import vmnet

/// A vmnet network the guest attaches to instead of Virtualization.framework NAT.
public struct GuestNetwork: @unchecked Sendable {
    public let reference: vmnet_network_ref
    /// The MAC address the network allocated for the guest, or nil for a random one.
    public let macAddress: String?

    public init(reference: vmnet_network_ref, macAddress: String?) {
        self.reference = reference
        self.macAddress = macAddress
    }
}

/// How a guest run ended.
public struct GuestExit: Sendable, Equatable {
    public let exitCode: Int32
    public let exitedAt: Date

    public init(exitCode: Int32, exitedAt: Date = Date()) {
        self.exitCode = exitCode
        self.exitedAt = exitedAt
    }
}

/// Runs one macOS guest from a `MacOSVMBundle`.
///
/// All Virtualization.framework calls run on a private serial queue.
public final class MacOSVirtualMachine: NSObject, @unchecked Sendable {
    /// Exit code when the guest shuts itself down.
    public static let guestShutdownExitCode: Int32 = 0
    /// Exit code when the virtual machine stops with an error.
    public static let errorExitCode: Int32 = 1
    /// Exit code when the host stops the guest without a guest shutdown.
    public static let forcedStopExitCode: Int32 = 137
    /// The smallest memory size the runtime gives a guest.
    public static let minimumMemoryInBytes: UInt64 = 4 << 30

    private let queue: DispatchQueue
    private let virtualMachine: VZVirtualMachine
    /// The MAC address of the guest's network device, which names its DHCP lease.
    public let macAddress: String
    private let auxiliaryStoragePath: String
    private let latch = ExitLatch()

    public init(bundle: MacOSVMBundle, cpus: Int, memoryInBytes: UInt64, network: GuestNetwork? = nil) throws {
        let configuration = try Self.configuration(bundle: bundle, cpus: cpus, memoryInBytes: memoryInBytes, network: network)
        self.macAddress = configuration.networkDevices.first?.macAddress.string ?? ""
        self.auxiliaryStoragePath = bundle.auxiliaryStorageURL.path
        let queue = DispatchQueue(label: "container-runtime-macos.vm")
        self.queue = queue
        self.virtualMachine = queue.sync { VZVirtualMachine(configuration: configuration, queue: queue) }
        super.init()
        queue.sync { self.virtualMachine.delegate = self }
    }

    /// The CPU count and memory size a guest gets for the request: each clamped to the range the host
    /// allows, with the memory raised to at least `minimumMemoryInBytes`.
    static func resources(
        cpus: Int, memoryInBytes: UInt64, minimum: (cpus: Int, memory: UInt64), maximum: (cpus: Int, memory: UInt64)
    ) -> (cpus: Int, memory: UInt64) {
        (
            cpus: min(max(cpus, minimum.cpus), maximum.cpus),
            memory: min(max(memoryInBytes, minimumMemoryInBytes, minimum.memory), maximum.memory)
        )
    }

    /// Builds a validated configuration for the guest in `bundle`.
    ///
    /// Clamps `cpus` to the range Virtualization.framework allows and raises
    /// `memoryInBytes` to at least `minimumMemoryInBytes`. The guest attaches to `network`, or to
    /// Virtualization.framework NAT without one.
    public static func configuration(
        bundle: MacOSVMBundle, cpus: Int, memoryInBytes: UInt64, network guestNetwork: GuestNetwork? = nil
    ) throws -> VZVirtualMachineConfiguration {
        guard let hardwareModelData = try? Data(contentsOf: bundle.hardwareModelURL),
            let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData)
        else {
            throw RuntimeFailure.invalidArgument("invalid hardware model in \(bundle.url.path)")
        }
        guard hardwareModel.isSupported else {
            throw RuntimeFailure.unsupported("this host does not support the hardware model in \(bundle.url.path)")
        }
        guard let machineIdentifierData = try? Data(contentsOf: bundle.machineIdentifierURL),
            let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData)
        else {
            throw RuntimeFailure.invalidArgument("invalid machine identifier in \(bundle.url.path)")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        let granted = resources(
            cpus: cpus, memoryInBytes: memoryInBytes,
            minimum: (VZVirtualMachineConfiguration.minimumAllowedCPUCount, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
            maximum: (VZVirtualMachineConfiguration.maximumAllowedCPUCount, VZVirtualMachineConfiguration.maximumAllowedMemorySize))
        configuration.cpuCount = granted.cpus
        configuration.memorySize = granted.memory

        let disk = try bundle.storageDeviceAttachment()
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        if let guestNetwork {
            network.attachment = VZVmnetNetworkDeviceAttachment(network: guestNetwork.reference)
            if let macAddress = guestNetwork.macAddress {
                guard let address = VZMACAddress(string: macAddress) else {
                    throw RuntimeFailure.invalidArgument("invalid MAC address \(macAddress)")
                }
                network.macAddress = address
            }
        } else {
            network.attachment = VZNATNetworkDeviceAttachment()
        }
        configuration.networkDevices = [network]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // The guest agent connects over vsock.
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        try configuration.validate()
        return configuration
    }

    /// Boots the guest.
    ///
    /// Virtualization.framework runs at most two macOS guests per host; a start beyond that fails
    /// with `RuntimeFailure.vmLimitReached`.
    public func start() async throws {
        do {
            try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
                queue.async {
                    self.virtualMachine.start { result in
                        cc.resume(with: result)
                    }
                }
            }
        } catch {
            throw Self.mapStartError(error)
        }
    }

    /// Boots the guest with `options`.
    ///
    /// Retries for up to `lockTimeout` while another process, such as the installer that has
    /// just exited, still holds the lock on the auxiliary storage, then throws
    /// `RuntimeFailure.lockHeld`. The guest limit fails at once with `RuntimeFailure.vmLimitReached`.
    public func start(options: VZMacOSVirtualMachineStartOptions, lockTimeout: Duration = .seconds(30)) async throws {
        // The options are read only on the virtual machine's queue.
        nonisolated(unsafe) let options = options
        try await Self.retryOnLockContention(path: auxiliaryStoragePath, timeout: lockTimeout, every: .seconds(2)) {
            try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
                queue.async {
                    self.virtualMachine.start(options: options) { error in
                        if let error {
                            cc.resume(throwing: error)
                        } else {
                            cc.resume()
                        }
                    }
                }
            }
        }
    }

    /// Runs `start` until it succeeds, retrying every `every` while its error is a lock contention.
    ///
    /// - Throws: `RuntimeFailure.lockHeld` for `path` when the contention outlasts `timeout`;
    ///   `RuntimeFailure.vmLimitReached` or any other start error at once.
    static func retryOnLockContention(
        path: String, timeout: Duration, every: Duration,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @Sendable () -> ContinuousClock.Instant = { .now },
        _ start: () async throws -> Void
    ) async throws {
        let started = try await GuestReachability.poll(every: every, timeout: timeout, sleep: sleep, now: now) { () async throws -> Bool? in
            do {
                try await start()
                return true
            } catch {
                let mapped = mapStartError(error)
                guard isLockContention(mapped) else {
                    throw mapped
                }
                return nil
            }
        }
        guard started != nil else {
            throw RuntimeFailure.lockHeld(path: path, holder: nil)
        }
    }

    /// Maps a start failure to the error the runtime reports: the guest limit, at the top or as a
    /// wrapped error, becomes `RuntimeFailure.vmLimitReached`; any other error is returned as is.
    static func mapStartError(_ error: any Error) -> any Error {
        let isLimit = errorChain(error).contains { $0.domain == VZError.errorDomain && $0.code == VZError.Code.virtualMachineLimitExceeded.rawValue }
        return isLimit ? RuntimeFailure.vmLimitReached : error
    }

    /// Whether `error`, or an error it wraps, is a POSIX `EAGAIN`, which is how
    /// Virtualization.framework reports an auxiliary storage that another process holds.
    static func isLockContention(_ error: any Error) -> Bool {
        errorChain(error).contains { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EAGAIN) }
    }

    /// `error` followed by the errors it wraps through `NSUnderlyingErrorKey`, each at most once.
    private static func errorChain(_ error: any Error) -> [NSError] {
        var chain: [NSError] = []
        var seen = Set<ObjectIdentifier>()
        var current: NSError? = error as NSError
        while let nsError = current, seen.insert(ObjectIdentifier(nsError)).inserted {
            chain.append(nsError)
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    /// Installs macOS from the restore image at `restoreImageURL` onto the guest's disk.
    ///
    /// Calls `progress` with the completed fraction, from 0 to 1, whenever it changes.
    public func install(restoreImageURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let queue = self.queue
        nonisolated(unsafe) let installer = queue.sync {
            VZMacOSInstaller(virtualMachine: self.virtualMachine, restoringFromImageAt: restoreImageURL)
        }

        let reporter = Task {
            var reported = -1.0
            while !Task.isCancelled {
                let fraction = queue.sync { installer.progress.fractionCompleted }
                if fraction != reported {
                    progress(fraction)
                    reported = fraction
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { reporter.cancel() }

        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
            queue.async {
                installer.install { result in
                    cc.resume(with: result)
                }
            }
        }
        progress(1)
    }

    /// Connects to `port` on the guest's vsock device and returns the connection as a file handle.
    ///
    /// The handle does not close the descriptor when it is released: the consumer that takes the
    /// descriptor over, such as a NIO channel, closes it.
    public func connect(toPort port: UInt32) async throws -> FileHandle {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<FileHandle, any Error>) in
            queue.async {
                guard let socketDevice = self.virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
                    cc.resume(throwing: RuntimeFailure.invalidState("the virtual machine has no vsock device"))
                    return
                }
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let connection):
                        let descriptor = dup(connection.fileDescriptor)
                        connection.close()
                        guard descriptor >= 0 else {
                            cc.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                            return
                        }
                        cc.resume(returning: FileHandle(fileDescriptor: descriptor, closeOnDealloc: false))
                    case .failure(let error):
                        cc.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Waits for the guest to connect to `port` on the host and returns the first connection as a
    /// file handle that closes its descriptor when released; the listener is removed afterwards.
    ///
    /// The listener is in place when this returns its task's first suspension, so start it before
    /// asking the guest to connect.
    public func accept(onPort port: UInt32, timeout: Duration) async throws -> FileHandle {
        let listener = try listen(onPort: port)
        defer { listener.close() }
        return try await listener.accept(timeout: timeout)
    }

    /// Listens on `port` on the host; the listener is in place when this returns.
    public func listen(onPort port: UInt32) throws -> VsockPortListener {
        guard let socketDevice = queue.sync(execute: { virtualMachine.socketDevices.first as? VZVirtioSocketDevice }) else {
            throw RuntimeFailure.invalidState("the virtual machine has no vsock device")
        }
        let acceptor = VsockAcceptor()
        let listener = VZVirtioSocketListener()
        listener.delegate = acceptor
        queue.sync { socketDevice.setSocketListener(listener, forPort: port) }
        return VsockPortListener(port: port, acceptor: acceptor) { [self] in
            queue.sync { (virtualMachine.socketDevices.first as? VZVirtioSocketDevice)?.removeSocketListener(forPort: port) }
        }
    }

    /// Pauses the guest and writes its memory and device state to `url`; the guest stays paused.
    public func saveState(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
            queue.async {
                self.virtualMachine.pause { result in
                    if case .failure(let error) = result {
                        cc.resume(throwing: error)
                        return
                    }
                    self.virtualMachine.saveMachineStateTo(url: url) { error in
                        if let error {
                            cc.resume(throwing: error)
                        } else {
                            cc.resume()
                        }
                    }
                }
            }
        }
    }

    /// Restores the state saved at `url` into this virtual machine instead of booting it, and
    /// resumes the guest. The configuration must match the one the state was saved with.
    public func restoreState(from url: URL) async throws {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
            queue.async {
                self.virtualMachine.restoreMachineStateFrom(url: url) { error in
                    if let error {
                        cc.resume(throwing: error)
                        return
                    }
                    self.virtualMachine.resume { result in
                        cc.resume(with: result)
                    }
                }
            }
        }
    }

    /// Asks the guest to shut down, like a press of the power button. A guest that already stopped
    /// has nothing to stop, so the request returns without error.
    public func requestStop() async throws {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard self.virtualMachine.canRequestStop else {
                    cc.resume()
                    return
                }
                do {
                    try self.virtualMachine.requestStop()
                    cc.resume()
                } catch {
                    cc.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the guest immediately, without a guest shutdown.
    public func forceStop() async throws {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
            queue.async {
                self.virtualMachine.stop { error in
                    if let error {
                        cc.resume(throwing: error)
                        return
                    }
                    self.finish(exitCode: Self.forcedStopExitCode)
                    cc.resume()
                }
            }
        }
    }

    /// Waits until the guest stops.
    public func wait() async -> GuestExit {
        await latch.wait()
    }

    /// Waits until the guest stops or `timeout` passes, and returns nil on timeout.
    ///
    /// Returns as soon as the guest stops.
    public func wait(timeout: Duration) async -> GuestExit? {
        await latch.wait(timeout: timeout)
    }

    /// The exit of the guest, or nil while it runs.
    public var currentExit: GuestExit? {
        latch.current
    }

    func finish(exitCode: Int32) {
        latch.finish(exitCode: exitCode)
    }
}

extension MacOSVirtualMachine: VZVirtualMachineDelegate {
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        finish(exitCode: Self.guestShutdownExitCode)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        finish(exitCode: Self.errorExitCode)
    }
}

/// A host vsock port the guest connects to once.
public final class VsockPortListener: Sendable {
    public let port: UInt32
    private let acceptor: VsockAcceptor
    private let remove: @Sendable () -> Void

    fileprivate init(port: UInt32, acceptor: VsockAcceptor, remove: @escaping @Sendable () -> Void) {
        self.port = port
        self.acceptor = acceptor
        self.remove = remove
    }

    /// Returns the guest's first connection as a file handle that closes its descriptor when released.
    public func accept(timeout: Duration) async throws -> FileHandle {
        try await acceptor.connection(timeout: timeout, port: port)
    }

    /// Stops listening; a later connection to the port is refused.
    public func close() {
        remove()
    }
}

/// Hands the first connection a vsock listener accepts to one waiting task.
private final class VsockAcceptor: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FileHandle, any Error>?
    private var accepted: FileHandle?
    private var finished = false

    func listener(
        _ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let descriptor = dup(connection.fileDescriptor)
        connection.close()
        guard descriptor >= 0 else {
            return false
        }
        finish(.success(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)))
        return true
    }

    func connection(timeout: Duration, port: UInt32) async throws -> FileHandle {
        try await withCheckedThrowingContinuation { cc in
            let ready: FileHandle? = lock.withLock {
                if let accepted {
                    return accepted
                }
                continuation = cc
                return nil
            }
            if let ready {
                cc.resume(returning: ready)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.finish(.failure(RuntimeFailure.timeout("the guest did not connect to vsock port \(port)")))
            }
        }
    }

    private func finish(_ result: Result<FileHandle, any Error>) {
        let waiting: CheckedContinuation<FileHandle, any Error>? = lock.withLock {
            guard !finished else {
                return nil
            }
            if continuation == nil, case .success(let handle) = result {
                accepted = handle
                return nil
            }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
