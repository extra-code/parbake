// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Darwin
import Foundation
import Virtualization

/// A directory holding an installed macOS guest.
///
/// The layout matches Apple's "Running macOS in a virtual machine on Apple silicon"
/// sample: a disk image, the auxiliary storage, and the data representations of the
/// hardware model and the machine identifier.
public struct MacOSVMBundle: Sendable {
    public static let diskImageName = "Disk.img"
    public static let auxiliaryStorageName = "AuxiliaryStorage"
    public static let hardwareModelName = "HardwareModel"
    public static let machineIdentifierName = "MachineIdentifier"

    static let fileNames = [diskImageName, auxiliaryStorageName, hardwareModelName, machineIdentifierName]

    public let url: URL

    /// Opens the bundle at `url` and checks that every file of the layout exists.
    public init(url: URL) throws {
        for name in Self.fileNames {
            let path = url.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else {
                throw ContainerizationError(.notFound, message: "macOS VM bundle \(url.path) is missing \(name)")
            }
        }
        self.url = url
    }

    public var diskImageURL: URL { url.appendingPathComponent(Self.diskImageName) }
    public var auxiliaryStorageURL: URL { url.appendingPathComponent(Self.auxiliaryStorageName) }
    public var hardwareModelURL: URL { url.appendingPathComponent(Self.hardwareModelName) }
    public var machineIdentifierURL: URL { url.appendingPathComponent(Self.machineIdentifierName) }

    /// Creates an empty bundle at `url` for a guest with `hardwareModel`.
    ///
    /// The disk image is a sparse file of `diskSizeInBytes`, and the machine identifier
    /// is new. Install macOS into the bundle before booting it.
    public static func create(at url: URL, hardwareModel: VZMacHardwareModel, diskSizeInBytes: UInt64) throws -> MacOSVMBundle {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ContainerizationError(.exists, message: "\(url.path) already exists")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let diskImageURL = url.appendingPathComponent(diskImageName)
        guard FileManager.default.createFile(atPath: diskImageURL.path, contents: nil) else {
            throw ContainerizationError(.internalError, message: "failed to create \(diskImageURL.path)")
        }
        let disk = try FileHandle(forWritingTo: diskImageURL)
        defer { try? disk.close() }
        try disk.truncate(atOffset: diskSizeInBytes)

        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: url.appendingPathComponent(auxiliaryStorageName),
            hardwareModel: hardwareModel
        )
        try hardwareModel.dataRepresentation.write(to: url.appendingPathComponent(hardwareModelName))
        try VZMacMachineIdentifier().dataRepresentation.write(to: url.appendingPathComponent(machineIdentifierName))

        return try MacOSVMBundle(url: url)
    }

    /// Clones the bundle into `destination` with APFS copy-on-write clones.
    ///
    /// The clone shares unchanged blocks with the source, so it takes no extra space
    /// up front and the guest's writes never reach the source bundle.
    public func clone(to destination: URL) throws -> MacOSVMBundle {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in Self.fileNames {
            let source = url.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            guard clonefile(source.path, target.path, 0) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw ContainerizationError(
                    .internalError,
                    message: "failed to clone \(source.path) to \(target.path)",
                    cause: POSIXError(code)
                )
            }
        }
        return try MacOSVMBundle(url: destination)
    }
}
