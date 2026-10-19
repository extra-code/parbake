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

    /// Written by provisioning; its content is the username of the guest account.
    public static let provisionedName = "Provisioned"
    /// Private key that the host uses to log in to the guest account, written by provisioning.
    public static let guestKeyName = "GuestKey"
    /// Written when the guest agent is installed; its content is the agent's version line.
    public static let agentName = "Agent"
    /// The writable top layer of an instance whose disk image is a link to an ASIF base.
    public static let overlayImageName = "Overlay.asif"

    static let fileNames = [diskImageName, auxiliaryStorageName, hardwareModelName, machineIdentifierName]

    /// The overlay of an instance no longer stacks on its base, for example after the base bundle
    /// was installed again.
    public struct IncompatibleOverlayError: Error, CustomStringConvertible {
        public let bundle: URL
        public let base: URL
        public let reason: String

        public var description: String {
            "the overlay in \(bundle.path) does not stack on \(base.path): \(reason)"
        }
    }

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
    public var provisionedURL: URL { url.appendingPathComponent(Self.provisionedName) }
    public var guestKeyURL: URL { url.appendingPathComponent(Self.guestKeyName) }
    public var agentURL: URL { url.appendingPathComponent(Self.agentName) }

    /// The version line of the guest agent installed in the guest, or nil without one.
    public var agentVersion: String? {
        guard let content = try? String(contentsOf: agentURL, encoding: .utf8) else {
            return nil
        }
        let version = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// The guest account's username when provisioning created it, or nil.
    public var provisionedUsername: String? {
        guard let content = try? String(contentsOf: provisionedURL, encoding: .utf8) else {
            return nil
        }
        let username = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? nil : username
    }

    /// A shell that logs in to the guest with the provisioned account and the guest key, or nil
    /// when the bundle has neither.
    public var guestShell: GuestShell? {
        guard let username = provisionedUsername, FileManager.default.fileExists(atPath: guestKeyURL.path) else {
            return nil
        }
        return GuestShell(username: username, credential: .key(guestKeyURL))
    }

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
        } catch let error as IncompatibleStackingError {
            throw IncompatibleOverlayError(bundle: url, base: diskImageURL.resolvingSymlinksInPath(), reason: error.localizedDescription)
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
    /// clones, and so are the provisioning files and the agent version when the bundle has them. The
    /// machine identifier is new, so every instance has its own serial number and platform UUID.
    public func instance(at destination: URL) throws -> MacOSVMBundle {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Self.cloneFiles([Self.auxiliaryStorageName, Self.hardwareModelName], from: url, to: destination)
        let provisioningFiles = [Self.provisionedName, Self.guestKeyName, Self.agentName].filter {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
        try Self.cloneFiles(provisioningFiles, from: url, to: destination)
        try VZMacMachineIdentifier().dataRepresentation.write(to: destination.appendingPathComponent(Self.machineIdentifierName))
        guard #available(macOS 27, *), try diskFormat() == .asif else {
            // A raw disk image copied across volumes takes its full size; only a clone is cheap.
            try Self.cloneFiles([Self.diskImageName], from: url, to: destination, copyWhenNotClonable: false)
            return try MacOSVMBundle(url: destination)
        }
        try linkBaseAndCreateOverlay(in: destination)
        return try MacOSVMBundle(url: destination)
    }

    /// Discards this instance's overlay and starts it over on `source`: the disk image link, the
    /// auxiliary storage and the overlay are made anew from `source`, the machine identifier stays.
    ///
    /// The guest's writes since the instance was created are lost.
    @available(macOS 27, *)
    public func resetOverlay(from source: MacOSVMBundle) throws {
        guard try source.diskFormat() == .asif else {
            throw ContainerizationError(.invalidArgument, message: "\(source.url.path) has no ASIF disk image to stack an overlay on")
        }
        for name in [Self.overlayImageName, Self.diskImageName, Self.auxiliaryStorageName] {
            let file = url.appendingPathComponent(name)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil || FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        try Self.cloneFiles([Self.auxiliaryStorageName], from: source.url, to: url)
        try source.linkBaseAndCreateOverlay(in: url)
    }

    /// Links this bundle's disk image as `Disk.img` in `destination` and creates an ASIF overlay on it there.
    @available(macOS 27, *)
    private func linkBaseAndCreateOverlay(in destination: URL) throws {
        let diskImageLink = destination.appendingPathComponent(Self.diskImageName)
        try FileManager.default.createSymbolicLink(at: diskImageLink, withDestinationURL: diskImageURL.resolvingSymlinksInPath())
        let overlayURL = destination.appendingPathComponent(Self.overlayImageName)
        do {
            let base = try DiskImage(opening: .open(url: diskImageLink, mode: .readOnly))
            _ = try base.appending(.asifLayer(url: overlayURL, type: .overlay))
        } catch {
            throw ContainerizationError(.internalError, message: "failed to create \(overlayURL.path)", cause: error)
        }
    }

    /// Clones the bundle into `destination` with APFS copy-on-write clones.
    ///
    /// The clone shares unchanged blocks with the source, so it takes no extra space
    /// up front and the guest's writes never reach the source bundle.
    public func clone(to destination: URL) throws -> MacOSVMBundle {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Self.cloneFiles(Self.fileNames, from: url, to: destination, copyWhenNotClonable: false)
        return try MacOSVMBundle(url: destination)
    }

    /// Clones `names` from `url` into `destination` with APFS copy-on-write clones. Where no clone
    /// is possible, because `destination` is on another volume or not on APFS, the files are copied
    /// when `copyWhenNotClonable` is set and the call fails otherwise.
    private static func cloneFiles(_ names: [String], from url: URL, to destination: URL, copyWhenNotClonable: Bool = true) throws {
        for name in names {
            let source = url.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            guard clonefile(source.path, target.path, 0) != 0 else {
                continue
            }
            let cloneError = errno
            guard cloneError == EXDEV || cloneError == ENOTSUP else {
                throw ContainerizationError(
                    .internalError, message: "failed to clone \(source.path) to \(target.path)",
                    cause: POSIXError(POSIXErrorCode(rawValue: cloneError) ?? .EIO))
            }
            guard copyWhenNotClonable else {
                throw ContainerizationError(
                    .unsupported,
                    message: "cannot clone \(source.path) to \(target.path): both must be on the same APFS volume; "
                        + "a bundle with an ASIF disk image, the default on macOS 27, may live on another volume")
            }
            guard copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                throw ContainerizationError(
                    .internalError, message: "failed to copy \(source.path) to \(target.path)",
                    cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
        }
    }
}
