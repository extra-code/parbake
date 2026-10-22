// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Darwin
import DiskImageKit
import Foundation
import ParbakeVersion
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
    /// The layer of a layer bundle, between the base disk image and an instance's overlay, for
    /// example one with Xcode. Writable while the layer bundle is built, read-only under an overlay.
    public static let layerImageName = "Layer.asif"

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
    ///
    /// An instance whose disk image link is not backed by an overlay, or whose layer link has no
    /// overlay, was left half-built; it is refused so that nothing opens the shared base writable.
    public init(url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RuntimeFailure.bundleMissing(path: url.path, missing: nil)
        }
        for name in Self.fileNames {
            let path = url.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else {
                throw RuntimeFailure.bundleMissing(path: url.path, missing: name)
            }
        }
        self.url = url
        if isIncompleteInstance {
            throw ContainerizationError(.invalidState, message: "\(url.path) is an incomplete instance; remove the container")
        }
    }

    public var diskImageURL: URL { url.appendingPathComponent(Self.diskImageName) }
    public var auxiliaryStorageURL: URL { url.appendingPathComponent(Self.auxiliaryStorageName) }
    public var hardwareModelURL: URL { url.appendingPathComponent(Self.hardwareModelName) }
    public var machineIdentifierURL: URL { url.appendingPathComponent(Self.machineIdentifierName) }
    public var overlayImageURL: URL { url.appendingPathComponent(Self.overlayImageName) }
    public var layerImageURL: URL { url.appendingPathComponent(Self.layerImageName) }

    /// Whether this is a layer bundle, or an instance of one.
    public var hasLayer: Bool { FileManager.default.fileExists(atPath: layerImageURL.path) }
    private var hasOverlay: Bool { FileManager.default.fileExists(atPath: overlayImageURL.path) }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Whether the links of an instance exist without the overlay that makes them safe to open: a
    /// linked base without an overlay or a regular layer, or a linked layer without an overlay.
    private var isIncompleteInstance: Bool {
        guard !hasOverlay else { return false }
        if Self.isSymbolicLink(layerImageURL) { return true }
        return Self.isSymbolicLink(diskImageURL) && !hasLayer
    }
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

    /// The parsed version line of the guest agent, or nil without one or when it is malformed.
    public var agentVersionLine: AgentVersionLine? {
        agentVersion.flatMap { AgentVersionLine($0) }
    }

    /// The guest account's username when provisioning created it, or nil when the file is
    /// missing or its content is not a valid `GuestUsername`.
    public var provisionedUsername: String? {
        guard let content = try? String(contentsOf: provisionedURL, encoding: .utf8) else {
            return nil
        }
        let username = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return GuestUsername(rawValue: username)?.rawValue
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
    /// layer and the overlay stacked on it when the bundle has them. Only the top layer is
    /// writable: the overlay of an instance, or the layer of a layer bundle.
    public func storageDeviceAttachment() throws -> VZDiskImageStorageDeviceAttachment {
        guard !isIncompleteInstance else {
            throw ContainerizationError(.invalidState, message: "\(url.path) is an incomplete instance; remove the container")
        }
        guard hasOverlay || hasLayer else {
            return try VZDiskImageStorageDeviceAttachment(url: diskImageURL, readOnly: false)
        }
        do {
            var stack = try DiskImage(opening: .open(url: diskImageURL, mode: .readOnly))
            if hasLayer {
                let layer = try DiskImage(opening: .open(url: layerImageURL, mode: hasOverlay ? .readOnly : .readWrite))
                stack = try stack.appending(layer)
            }
            if hasOverlay {
                stack = try stack.appending(try DiskImage(opening: .open(url: overlayImageURL)))
            }
            return try VZDiskImageStorageDeviceAttachment(diskImage: stack)
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
    ///
    /// An instance of a layer bundle links its layer too, so the overlay stacks on base and layer.
    public func instance(at destination: URL) throws -> MacOSVMBundle {
        guard !hasOverlay else {
            throw ContainerizationError(.unsupported, message: "\(url.path) is a container's instance, not a bundle")
        }
        try checkDiskImageIsASIF()
        try Self.build(at: destination) { staging in
            try copyBundleFiles(to: staging)
            try linkBaseAndCreateOverlay(in: staging)
        }
        return try MacOSVMBundle(url: destination)
    }

    /// Runs `body` on `<destination>.parbake-new` and renames that directory to `destination`
    /// when it returns. `destination` never exists half-built; the staging directory is removed
    /// when `body` or the rename throws.
    private static func build(at destination: URL, _ body: (URL) throws -> Void) throws {
        var isLink = stat()
        guard lstat(destination.path, &isLink) != 0 else {
            throw ContainerizationError(.exists, message: "\(destination.path) already exists")
        }
        let staging = URL(fileURLWithPath: destination.path + ".parbake-new")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try body(staging)
            guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw ContainerizationError(
                    .internalError, message: "failed to move \(staging.path) to \(destination.path)",
                    cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Creates a layer bundle in `destination` on this bundle; this bundle stays unchanged.
    ///
    /// The layer bundle links this bundle's disk image like an instance, and writes into a new
    /// ASIF layer bound to the image's layer UUID. Booted on its own, the layer bundle writes to
    /// its layer; its instances read the layer and write to their overlays. A layer bundle cannot
    /// be the base of another one: Apple advises against deep stacks, and base, layer and overlay
    /// are three levels.
    public func layerBundle(at destination: URL) throws -> MacOSVMBundle {
        guard !hasOverlay else {
            throw ContainerizationError(.unsupported, message: "\(url.path) is a container's instance, not a bundle")
        }
        try checkDiskImageIsASIF()
        guard !hasLayer else {
            throw ContainerizationError(.unsupported, message: "\(url.path) is a layer bundle; a layer stacks on a base bundle only")
        }
        try copyBundleFiles(to: destination)
        let diskImageLink = try linkDiskImage(in: destination)
        let layerURL = destination.appendingPathComponent(Self.layerImageName)
        do {
            let base = try DiskImage(opening: .open(url: diskImageLink, mode: .readOnly))
            _ = try base.appending(.asifLayer(url: layerURL, type: .overlay))
        } catch {
            throw ContainerizationError(.internalError, message: "failed to create \(layerURL.path)", cause: error)
        }
        return try MacOSVMBundle(url: destination)
    }

    /// Clones the auxiliary storage, the hardware model and the provisioning files into
    /// `destination`, and writes a new machine identifier there.
    private func copyBundleFiles(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Self.cloneFiles([Self.auxiliaryStorageName, Self.hardwareModelName], from: url, to: destination)
        let provisioningFiles = [Self.provisionedName, Self.guestKeyName, Self.agentName].filter {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
        try Self.cloneFiles(provisioningFiles, from: url, to: destination)
        try VZMacMachineIdentifier().dataRepresentation.write(to: destination.appendingPathComponent(Self.machineIdentifierName))
    }

    /// Discards this instance's overlay and starts it over on `source`: the disk image link, the
    /// layer link, the overlay, the auxiliary storage, the hardware model and the provisioning
    /// files are made anew from `source`, and files `source` lacks are removed. The machine
    /// identifier stays.
    ///
    /// The new set is built in `<instance>.parbake-reset`, so a failure while building leaves the
    /// instance as it was. The files are then moved in one by one, with the overlay last: the swap
    /// is not atomic, and a failure while moving leaves the files moved so far from `source` and
    /// the rest, the old overlay included, as they were. The guest's writes since the instance was
    /// created are lost once the overlay is moved.
    public func resetOverlay(from source: MacOSVMBundle) throws {
        try source.checkDiskImageIsASIF()
        let staging = URL(fileURLWithPath: url.path + ".parbake-reset")
        try? FileManager.default.removeItem(at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try source.copyBundleFiles(to: staging)
        try source.linkBaseAndCreateOverlay(in: staging)

        let replaced = [
            Self.diskImageName, Self.layerImageName, Self.auxiliaryStorageName, Self.hardwareModelName,
            Self.provisionedName, Self.guestKeyName, Self.agentName, Self.overlayImageName,
        ]
        for name in replaced {
            let staged = staging.appendingPathComponent(name)
            let target = url.appendingPathComponent(name)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: staged.path)) != nil
                || FileManager.default.fileExists(atPath: staged.path)
            {
                guard rename(staged.path, target.path) == 0 else {
                    throw ContainerizationError(
                        .internalError, message: "failed to move \(staged.path) to \(target.path)",
                        cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                }
            } else if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil
                || FileManager.default.fileExists(atPath: target.path)
            {
                try FileManager.default.removeItem(at: target)
            }
        }
    }

    /// Links this bundle's disk image as `Disk.img` in `destination` and returns the link.
    private func linkDiskImage(in destination: URL) throws -> URL {
        let diskImageLink = destination.appendingPathComponent(Self.diskImageName)
        try FileManager.default.createSymbolicLink(at: diskImageLink, withDestinationURL: diskImageURL.resolvingSymlinksInPath())
        return diskImageLink
    }

    /// Links this bundle's disk image, and its layer when it has one, in `destination` and
    /// creates an ASIF overlay on them there.
    private func linkBaseAndCreateOverlay(in destination: URL) throws {
        let diskImageLink = try linkDiskImage(in: destination)
        var layerLink: URL?
        if hasLayer {
            let link = destination.appendingPathComponent(Self.layerImageName)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: layerImageURL.resolvingSymlinksInPath())
            layerLink = link
        }
        let overlayURL = destination.appendingPathComponent(Self.overlayImageName)
        do {
            var stack = try DiskImage(opening: .open(url: diskImageLink, mode: .readOnly))
            if let layerLink {
                stack = try stack.appending(try DiskImage(opening: .open(url: layerLink, mode: .readOnly)))
            }
            _ = try stack.appending(.asifLayer(url: overlayURL, type: .overlay))
        } catch let error as IncompatibleStackingError {
            throw IncompatibleOverlayError(bundle: url, base: diskImageURL.resolvingSymlinksInPath(), reason: error.localizedDescription)
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
