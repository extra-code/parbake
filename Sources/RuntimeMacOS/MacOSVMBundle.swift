// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Darwin
import DiskImageKit
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

    /// The writable top layer of an instance whose disk image is a link to an ASIF base.
    public static let overlayImageName = "Overlay.asif"

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
    public var overlayImageURL: URL { url.appendingPathComponent(Self.overlayImageName) }

    /// The format of the bundle's disk image.
    public func diskFormat() throws -> DiskFormat {
        guard #available(macOS 27, *) else {
            return .raw
        }
        let image = try DiskImage(opening: .open(url: diskImageURL, mode: .readOnly))
        return image.format == .asif ? .asif : .raw
    }

    /// The storage the guest boots from: the disk image, or the disk image read-only with the
    /// overlay stacked on it when the bundle has one.
    public func storageDeviceAttachment() throws -> VZDiskImageStorageDeviceAttachment {
        guard FileManager.default.fileExists(atPath: overlayImageURL.path) else {
            return try VZDiskImageStorageDeviceAttachment(url: diskImageURL, readOnly: false)
        }
        guard #available(macOS 27, *) else {
            throw ContainerizationError(.unsupported, message: "\(url.path) has an overlay, which needs a macOS 27 or later host")
        }
        do {
            let base = try DiskImage(opening: .open(url: diskImageURL, mode: .readOnly))
            let overlay = try DiskImage(opening: .open(url: overlayImageURL))
            return try VZDiskImageStorageDeviceAttachment(diskImage: try base.appending(overlay))
        } catch {
            throw ContainerizationError(
                .invalidState,
                message: "the overlay in \(url.path) does not stack on \(diskImageURL.resolvingSymlinksInPath().path)",
                cause: error
            )
        }
    }

    /// The format of a new bundle's disk image.
    public enum DiskFormat: String, Sendable, CaseIterable {
        /// Apple Sparse Image Format (macOS 27 or later host): stays sparse when copied, and
        /// carries a layer UUID that overlays stacked on it are bound to.
        case asif
        /// One file block per disk block, sparse only on APFS.
        case raw

        /// ASIF where the host supports DiskImageKit, raw otherwise.
        public static var preferred: DiskFormat {
            if #available(macOS 27, *) { return .asif }
            return .raw
        }
    }

    /// Creates an empty bundle at `url` for a guest with `hardwareModel`.
    ///
    /// The disk image holds `diskSizeInBytes` in `diskFormat`, and the machine identifier
    /// is new. Install macOS into the bundle before booting it.
    public static func create(
        at url: URL, hardwareModel: VZMacHardwareModel, diskSizeInBytes: UInt64, diskFormat: DiskFormat = .preferred
    ) throws -> MacOSVMBundle {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ContainerizationError(.exists, message: "\(url.path) already exists")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try createDiskImage(at: url.appendingPathComponent(diskImageName), sizeInBytes: diskSizeInBytes, format: diskFormat)

        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: url.appendingPathComponent(auxiliaryStorageName),
            hardwareModel: hardwareModel
        )
        try hardwareModel.dataRepresentation.write(to: url.appendingPathComponent(hardwareModelName))
        try VZMacMachineIdentifier().dataRepresentation.write(to: url.appendingPathComponent(machineIdentifierName))

        return try MacOSVMBundle(url: url)
    }

    static func createDiskImage(at diskImageURL: URL, sizeInBytes: UInt64, format: DiskFormat) throws {
        switch format {
        case .asif:
            guard #available(macOS 27, *) else {
                throw ContainerizationError(.unsupported, message: "an ASIF disk image needs a macOS 27 or later host")
            }
            let blockSize = DiskImage.BlockSize.bytes512
            let blockCount = Int((sizeInBytes + UInt64(blockSize.rawValue) - 1) / UInt64(blockSize.rawValue))
            do {
                _ = try DiskImage(creating: .asif(url: diskImageURL, blockCount: blockCount, blockSize: blockSize))
            } catch {
                throw ContainerizationError(.internalError, message: "failed to create \(diskImageURL.path)", cause: error)
            }
        case .raw:
            guard FileManager.default.createFile(atPath: diskImageURL.path, contents: nil) else {
                throw ContainerizationError(.internalError, message: "failed to create \(diskImageURL.path)")
            }
            let disk = try FileHandle(forWritingTo: diskImageURL)
            defer { try? disk.close() }
            try disk.truncate(atOffset: sizeInBytes)
        }
    }

    /// Creates the bundle one container boots in `destination`; the source bundle stays unchanged.
    ///
    /// With an ASIF disk image, the instance links to that image, reads it read-only and writes
    /// into a new ASIF overlay that is bound to the image's layer UUID. With a raw disk image,
    /// the instance's disk is an APFS clone. The auxiliary storage and hardware model are APFS
    /// clones. The machine identifier is new, so every instance has its own serial number and
    /// platform UUID.
    public func instance(at destination: URL) throws -> MacOSVMBundle {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Self.cloneFiles([Self.auxiliaryStorageName, Self.hardwareModelName], from: url, to: destination)
        try VZMacMachineIdentifier().dataRepresentation.write(to: destination.appendingPathComponent(Self.machineIdentifierName))
        guard #available(macOS 27, *), try diskFormat() == .asif else {
            try Self.cloneFiles([Self.diskImageName], from: url, to: destination)
            return try MacOSVMBundle(url: destination)
        }
        let diskImageLink = destination.appendingPathComponent(Self.diskImageName)
        try FileManager.default.createSymbolicLink(at: diskImageLink, withDestinationURL: diskImageURL.resolvingSymlinksInPath())
        let overlayURL = destination.appendingPathComponent(Self.overlayImageName)
        do {
            let base = try DiskImage(opening: .open(url: diskImageLink, mode: .readOnly))
            _ = try base.appending(.asifLayer(url: overlayURL, type: .overlay))
        } catch {
            throw ContainerizationError(.internalError, message: "failed to create \(overlayURL.path)", cause: error)
        }
        return try MacOSVMBundle(url: destination)
    }

    /// Clones the bundle into `destination` with APFS copy-on-write clones.
    ///
    /// The clone shares unchanged blocks with the source, so it takes no extra space
    /// up front and the guest's writes never reach the source bundle.
    public func clone(to destination: URL) throws -> MacOSVMBundle {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Self.cloneFiles(Self.fileNames, from: url, to: destination)
        return try MacOSVMBundle(url: destination)
    }

    private static func cloneFiles(_ names: [String], from url: URL, to destination: URL) throws {
        for name in names {
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
    }
}
