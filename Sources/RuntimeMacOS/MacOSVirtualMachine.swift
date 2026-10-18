// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
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
    private let lock = NSLock()
    private var exit: GuestExit?
    private var waiters: [CheckedContinuation<GuestExit, Never>] = []

    public init(bundle: MacOSVMBundle, cpus: Int, memoryInBytes: UInt64, network: GuestNetwork? = nil) throws {
        let configuration = try Self.configuration(bundle: bundle, cpus: cpus, memoryInBytes: memoryInBytes, network: network)
        self.macAddress = configuration.networkDevices.first?.macAddress.string ?? ""
        let queue = DispatchQueue(label: "container-runtime-macos.vm")
        self.queue = queue
        self.virtualMachine = queue.sync { VZVirtualMachine(configuration: configuration, queue: queue) }
        super.init()
        queue.sync { self.virtualMachine.delegate = self }
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
            throw ContainerizationError(.invalidArgument, message: "invalid hardware model in \(bundle.url.path)")
        }
        guard hardwareModel.isSupported else {
            throw ContainerizationError(.unsupported, message: "this host does not support the hardware model in \(bundle.url.path)")
        }
        guard let machineIdentifierData = try? Data(contentsOf: bundle.machineIdentifierURL),
            let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData)
        else {
            throw ContainerizationError(.invalidArgument, message: "invalid machine identifier in \(bundle.url.path)")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = min(
            max(cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount
        )
        configuration.memorySize = min(
            max(memoryInBytes, minimumMemoryInBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
            VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )

        let disk = try bundle.storageDeviceAttachment()
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        if let guestNetwork {
            guard #available(macOS 26, *) else {
                throw ContainerizationError(.unsupported, message: "a vmnet network attachment needs a macOS 26 or later host")
            }
            network.attachment = VZVmnetNetworkDeviceAttachment(network: guestNetwork.reference)
            if let macAddress = guestNetwork.macAddress {
                guard let address = VZMACAddress(string: macAddress) else {
                    throw ContainerizationError(.invalidArgument, message: "invalid MAC address \(macAddress)")
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
    public func start() async throws {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
            queue.async {
                self.virtualMachine.start { result in
                    cc.resume(with: result)
                }
            }
        }
    }

    /// Boots the guest with `options`.
    ///
    /// Retries for up to `lockTimeout` while another process, such as the installer that has
    /// just exited, still holds the lock on the auxiliary storage.
    public func start(options: VZMacOSVirtualMachineStartOptions, lockTimeout: Duration = .seconds(30)) async throws {
        // The options are read only on the virtual machine's queue.
        nonisolated(unsafe) let options = options
        let deadline = ContinuousClock.now + lockTimeout
        while true {
            do {
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
                return
            } catch  where Self.isLockContention(error) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Whether `error`, or an error it wraps, is a POSIX `EAGAIN`, which is how
    /// Virtualization.framework reports an auxiliary storage that another process holds.
    static func isLockContention(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EAGAIN) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
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

    /// Asks the guest to shut down, like a press of the power button.
    public func requestStop() async throws {
        try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, any Error>) in
            queue.async {
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
        await withCheckedContinuation { cc in
            let exit = lock.withLock {
                if self.exit == nil {
                    self.waiters.append(cc)
                }
                return self.exit
            }
            if let exit {
                cc.resume(returning: exit)
            }
        }
    }

    /// Waits until the guest stops or `timeout` passes, and returns nil on timeout.
    ///
    /// Returns as soon as the guest stops.
    public func wait(timeout: Duration) async -> GuestExit? {
        let resumed = NSLock()
        nonisolated(unsafe) var done = false
        return await withCheckedContinuation { (cc: CheckedContinuation<GuestExit?, Never>) in
            let resume: @Sendable (GuestExit?) -> Void = { exit in
                let first = resumed.withLock {
                    defer { done = true }
                    return !done
                }
                if first {
                    cc.resume(returning: exit)
                }
            }
            Task { resume(await self.wait()) }
            Task {
                try? await Task.sleep(for: timeout)
                resume(self.currentExit)
            }
        }
    }


    /// The exit of the guest, or nil while it runs.
    public var currentExit: GuestExit? {
        lock.withLock { self.exit }
    }

    func finish(exitCode: Int32) {
        let (exit, pending): (GuestExit?, [CheckedContinuation<GuestExit, Never>]) = lock.withLock {
            guard self.exit == nil else {
                return (nil, [])
            }
            let exit = GuestExit(exitCode: exitCode)
            self.exit = exit
            let pending = self.waiters
            self.waiters = []
            return (exit, pending)
        }
        guard let exit else {
            return
        }
        for cc in pending {
            cc.resume(returning: exit)
        }
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
