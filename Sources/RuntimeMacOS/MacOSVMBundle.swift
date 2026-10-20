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

    /// Refuses a bundle whose disk image is not ASIF: only an ASIF image carries the layer UUID
    /// that binds a container's overlay to it.
    public func checkDiskImageIsASIF() throws {
        let image: DiskImage
        do {
            image = try DiskImage(opening: .open(url: diskImageURL, mode: .readOnly))
        } catch {
            throw ContainerizationError(.invalidArgument, message: "cannot open the disk image of \(url.path)", cause: error)
        }
        guard image.format == .asif else {
            throw ContainerizationError(
                .unsupported, message: "\(url.path) has a raw disk image; rebuild it with parbake create, which creates an ASIF disk image")
        }
    }

    /// The storage the guest boots from: the disk image, or the disk image read-only with the
    /// overlay stacked on it when the bundle has one.
    public func storageDeviceAttachment() throws -> VZDiskImageStorageDeviceAttachment {
        guard FileManager.default.fileExists(atPath: overlayImageURL.path) else {
            return try VZDiskImageStorageDeviceAttachment(url: diskImageURL, readOnly: false)
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

    /// Creates an empty bundle at `url` for a guest with `hardwareModel`.
    ///
    /// The disk image is an ASIF image of `diskSizeInBytes`, and the machine identifier is new.
    /// Install macOS into the bundle before booting it.
    public static func create(at url: URL, hardwareModel: VZMacHardwareModel, diskSizeInBytes: UInt64) throws -> MacOSVMBundle {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ContainerizationError(.exists, message: "\(url.path) already exists")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try createDiskImage(at: url.appendingPathComponent(diskImageName), sizeInBytes: diskSizeInBytes)

        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: url.appendingPathComponent(auxiliaryStorageName),
            hardwareModel: hardwareModel
        )
        try hardwareModel.dataRepresentation.write(to: url.appendingPathComponent(hardwareModelName))
        try VZMacMachineIdentifier().dataRepresentation.write(to: url.appendingPathComponent(machineIdentifierName))

        return try MacOSVMBundle(url: url)
    }

    static func createDiskImage(at diskImageURL: URL, sizeInBytes: UInt64) throws {
        let blockSize = DiskImage.BlockSize.bytes512
        let blockCount = Int((sizeInBytes + UInt64(blockSize.rawValue) - 1) / UInt64(blockSize.rawValue))
        do {
            _ = try DiskImage(creating: .asif(url: diskImageURL, blockCount: blockCount, blockSize: blockSize))
        } catch {
            throw ContainerizationError(.internalError, message: "failed to create \(diskImageURL.path)", cause: error)
        }
    }

    /// Creates the bundle one container boots in `destination`; the source bundle stays unchanged.
    ///
    /// The instance links to the bundle's ASIF disk image, reads it read-only and writes into a
    /// new ASIF overlay that is bound to the image's layer UUID. The auxiliary storage and hardware
    /// model are APFS clones, or copies on another volume, and so are the provisioning files and the
    /// agent version when the bundle has them. The machine identifier is new, so every instance has
    /// its own serial number and platform UUID. A bundle with a raw disk image is refused.
    public func instance(at destination: URL) throws -> MacOSVMBundle {
        try checkDiskImageIsASIF()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Self.cloneFiles([Self.auxiliaryStorageName, Self.hardwareModelName], from: url, to: destination)
        let provisioningFiles = [Self.provisionedName, Self.guestKeyName, Self.agentName].filter {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
        try Self.cloneFiles(provisioningFiles, from: url, to: destination)
        try VZMacMachineIdentifier().dataRepresentation.write(to: destination.appendingPathComponent(Self.machineIdentifierName))
        try linkBaseAndCreateOverlay(in: destination)
        return try MacOSVMBundle(url: destination)
    }

    /// Discards this instance's overlay and starts it over on `source`: the disk image link, the
    /// auxiliary storage and the overlay are made anew from `source`, the machine identifier stays.
    ///
    /// The guest's writes since the instance was created are lost.
    public func resetOverlay(from source: MacOSVMBundle) throws {
        try source.checkDiskImageIsASIF()
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

    /// Clones `names` from `url` into `destination` with APFS copy-on-write clones, and copies them
    /// where no clone is possible because `destination` is on another volume or not on APFS.
    private static func cloneFiles(_ names: [String], from url: URL, to destination: URL) throws {
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
            guard copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                throw ContainerizationError(
                    .internalError, message: "failed to copy \(source.path) to \(target.path)",
                    cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
        }
    }
}
