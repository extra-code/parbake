// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import DiskImageKit
import Foundation
import Testing
import Virtualization

@testable import RuntimeMacOS

struct MacOSVMBundleTests {
    private func makeBundleDirectory(omitting omitted: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vm-bundle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in MacOSVMBundle.fileNames where name != omitted {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    @Test
    func testOpenCompleteBundle() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try MacOSVMBundle(url: directory)

        #expect(bundle.diskImageURL.lastPathComponent == MacOSVMBundle.diskImageName)
        #expect(bundle.auxiliaryStorageURL.lastPathComponent == MacOSVMBundle.auxiliaryStorageName)
    }

    @Test(arguments: MacOSVMBundle.fileNames)
    func testOpenBundleMissingFileThrows(missing: String) throws {
        let directory = try makeBundleDirectory(omitting: missing)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: (any Error).self) {
            try MacOSVMBundle(url: directory)
        }
    }
}

struct DiskImageTests {
    @Test
    func testCreatesASparseASIFDiskImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vm-disk-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = directory.appendingPathComponent(MacOSVMBundle.diskImageName)

        try MacOSVMBundle.createDiskImage(at: disk, sizeInBytes: 64 << 30)

        let values = try disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        #expect((values.totalFileAllocatedSize ?? .max) < 64 << 20)
        #expect(try DiskImage(opening: .open(url: disk, mode: .readOnly)).format == .asif)
    }
}

struct InstanceTests {
    private func makeBundle() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vm-base-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in MacOSVMBundle.fileNames where name != MacOSVMBundle.diskImageName {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        try VZMacMachineIdentifier().dataRepresentation.write(to: directory.appendingPathComponent(MacOSVMBundle.machineIdentifierName))
        try MacOSVMBundle.createDiskImage(at: directory.appendingPathComponent(MacOSVMBundle.diskImageName), sizeInBytes: 1 << 30)
        return directory
    }

    @Test
    func testAnASIFBaseGetsAnOverlayBoundToIt() throws {
        let base = try makeBundle()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: destination)
        }

        let instance = try MacOSVMBundle(url: base).instance(at: destination)

        #expect(FileManager.default.fileExists(atPath: instance.overlayImageURL.path))
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: instance.diskImageURL.path)
        #expect(URL(fileURLWithPath: link).resolvingSymlinksInPath() == base.appendingPathComponent(MacOSVMBundle.diskImageName).resolvingSymlinksInPath())
        _ = try instance.storageDeviceAttachment()
    }

    @Test
    func testAnOverlayRefusesAnotherBase() throws {
        let base = try makeBundle()
        let other = try makeBundle()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            for url in [base, other, destination] { try? FileManager.default.removeItem(at: url) }
        }
        let instance = try MacOSVMBundle(url: base).instance(at: destination)

        try FileManager.default.removeItem(at: instance.diskImageURL)
        try FileManager.default.createSymbolicLink(
            at: instance.diskImageURL, withDestinationURL: other.appendingPathComponent(MacOSVMBundle.diskImageName))

        #expect(throws: (any Error).self) { try instance.storageDeviceAttachment() }
    }

    @Test
    func testARawBaseIsRefused() throws {
        let base = try makeBundle()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: destination)
        }
        // A raw disk image, as `parbake install --disk-format raw` used to create one.
        let disk = base.appendingPathComponent(MacOSVMBundle.diskImageName)
        try FileManager.default.removeItem(at: disk)
        try Data(count: 1 << 20).write(to: disk)

        #expect {
            try MacOSVMBundle(url: base).instance(at: destination)
        } throws: { error in
            "\(error)".contains("parbake create")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func testAnInstanceGetsANewMachineIdentifier() throws {
        let base = try makeBundle()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: destination)
        }

        let instance = try MacOSVMBundle(url: base).instance(at: destination)

        let sourceIdentifier = try Data(contentsOf: base.appendingPathComponent(MacOSVMBundle.machineIdentifierName))
        let instanceIdentifier = try Data(contentsOf: instance.machineIdentifierURL)
        #expect(VZMacMachineIdentifier(dataRepresentation: instanceIdentifier) != nil)
        #expect(instanceIdentifier != sourceIdentifier)
    }

    @Test
    func testAnInstanceKeepsTheAgentVersion() throws {
        let base = try makeBundle()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data("1 0.52.0\n".utf8).write(to: base.appendingPathComponent(MacOSVMBundle.agentName))

        let instance = try MacOSVMBundle(url: base).instance(at: destination)

        #expect(instance.agentVersion == "1 0.52.0")
    }
}

struct ResetOverlayTests {
    private func makeASIFBundle() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vm-base-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in MacOSVMBundle.fileNames where name != MacOSVMBundle.diskImageName {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        try VZMacMachineIdentifier().dataRepresentation.write(to: directory.appendingPathComponent(MacOSVMBundle.machineIdentifierName))
        try MacOSVMBundle.createDiskImage(at: directory.appendingPathComponent(MacOSVMBundle.diskImageName), sizeInBytes: 1 << 30)
        return directory
    }

    @Test
    func testAReinstalledBaseReportsAnIncompatibleOverlayAndResetStartsItOver() throws {
        let base = try makeASIFBundle()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: destination)
        }
        let source = try MacOSVMBundle(url: base)
        let instance = try source.instance(at: destination)
        let identifier = try Data(contentsOf: instance.machineIdentifierURL)

        // A new install replaces the base disk image at the same path, with a new layer UUID.
        try FileManager.default.removeItem(at: source.diskImageURL)
        try MacOSVMBundle.createDiskImage(at: source.diskImageURL, sizeInBytes: 1 << 30)
        #expect(throws: MacOSVMBundle.IncompatibleOverlayError.self) { try instance.storageDeviceAttachment() }

        try instance.resetOverlay(from: source)

        _ = try instance.storageDeviceAttachment()
        #expect(try Data(contentsOf: instance.machineIdentifierURL) == identifier)
        #expect(try Data(contentsOf: instance.auxiliaryStorageURL) == Data(MacOSVMBundle.auxiliaryStorageName.utf8))
    }
}

struct LayerBundleTests {
    private func makeBundle() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vm-base-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in MacOSVMBundle.fileNames where name != MacOSVMBundle.diskImageName {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        try MacOSVMBundle.createDiskImage(at: directory.appendingPathComponent(MacOSVMBundle.diskImageName), sizeInBytes: 1 << 30)
        return directory
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
    }

    private func uuids(of url: URL) throws -> (layer: UUID?, parent: UUID?) {
        let image = try DiskImage(opening: .open(url: url, mode: .readOnly))
        return (image.layerUUID, image.parentUUID)
    }

    @Test
    func testALayerStacksOnTheBaseAndAnInstanceOnTheLayer() throws {
        let base = try makeBundle()
        let layerURL = temporaryURL("vm-layer")
        let instanceURL = temporaryURL("vm-instance")
        defer {
            for url in [base, layerURL, instanceURL] { try? FileManager.default.removeItem(at: url) }
        }

        let layer = try MacOSVMBundle(url: base).layerBundle(at: layerURL)
        _ = try layer.storageDeviceAttachment()
        let instance = try layer.instance(at: instanceURL)
        _ = try instance.storageDeviceAttachment()

        let baseUUID = try uuids(of: base.appendingPathComponent(MacOSVMBundle.diskImageName)).layer
        let layerUUIDs = try uuids(of: layer.layerImageURL)
        let overlayUUIDs = try uuids(of: instance.overlayImageURL)
        #expect(layerUUIDs.parent == baseUUID)
        #expect(overlayUUIDs.parent == layerUUIDs.layer)
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: instance.layerImageURL.path)
        #expect(URL(fileURLWithPath: link).resolvingSymlinksInPath() == layer.layerImageURL.resolvingSymlinksInPath())
    }

    @Test
    func testALayerDoesNotStackOnALayer() throws {
        let base = try makeBundle()
        let layerURL = temporaryURL("vm-layer")
        let secondURL = temporaryURL("vm-layer")
        defer {
            for url in [base, layerURL, secondURL] { try? FileManager.default.removeItem(at: url) }
        }
        let layer = try MacOSVMBundle(url: base).layerBundle(at: layerURL)

        #expect {
            try layer.layerBundle(at: secondURL)
        } throws: { error in
            "\(error)".contains("layer bundle")
        }
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    }

    @Test
    func testAnInstanceRefusesALayerOfAnotherBase() throws {
        let base = try makeBundle()
        let other = try makeBundle()
        let layerURL = temporaryURL("vm-layer")
        let instanceURL = temporaryURL("vm-instance")
        defer {
            for url in [base, other, layerURL, instanceURL] { try? FileManager.default.removeItem(at: url) }
        }
        let layer = try MacOSVMBundle(url: base).layerBundle(at: layerURL)
        let instance = try layer.instance(at: instanceURL)

        // The base was built again: the layer no longer stacks on it.
        try FileManager.default.removeItem(at: layer.diskImageURL)
        try FileManager.default.createSymbolicLink(at: layer.diskImageURL, withDestinationURL: other.appendingPathComponent(MacOSVMBundle.diskImageName))
        try FileManager.default.removeItem(at: instance.diskImageURL)
        try FileManager.default.createSymbolicLink(at: instance.diskImageURL, withDestinationURL: other.appendingPathComponent(MacOSVMBundle.diskImageName))

        #expect(throws: MacOSVMBundle.IncompatibleOverlayError.self) { try instance.storageDeviceAttachment() }
        #expect(throws: MacOSVMBundle.IncompatibleOverlayError.self) { try layer.instance(at: temporaryURL("vm-instance")) }
    }

    @Test
    func testResettingAnInstanceOfALayerKeepsTheLayer() throws {
        let base = try makeBundle()
        let layerURL = temporaryURL("vm-layer")
        let instanceURL = temporaryURL("vm-instance")
        defer {
            for url in [base, layerURL, instanceURL] { try? FileManager.default.removeItem(at: url) }
        }
        let layer = try MacOSVMBundle(url: base).layerBundle(at: layerURL)
        let instance = try layer.instance(at: instanceURL)

        try instance.resetOverlay(from: layer)

        #expect(instance.hasLayer)
        #expect(try uuids(of: instance.overlayImageURL).parent == uuids(of: layer.layerImageURL).layer)
        _ = try instance.storageDeviceAttachment()
    }
}
