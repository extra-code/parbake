// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import DiskImageKit
import Foundation
import ParbakeVersion
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

        #expect {
            try MacOSVMBundle(url: directory)
        } throws: { error in
            (error as? RuntimeFailure) == .bundleMissing(path: directory.path, missing: missing)
        }
    }

    @Test
    func testOpenMissingDirectoryThrowsNotFound() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vm-bundle-\(UUID())")

        #expect {
            try MacOSVMBundle(url: directory)
        } throws: { error in
            (error as? RuntimeFailure) == .bundleMissing(path: directory.path, missing: nil)
        }
    }

    @Test
    func testALinkedDiskImageWithoutAnOverlayIsAnIncompleteInstance() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = directory.appendingPathComponent(MacOSVMBundle.diskImageName)
        try FileManager.default.removeItem(at: disk)
        try FileManager.default.createSymbolicLink(at: disk, withDestinationURL: directory.appendingPathComponent(MacOSVMBundle.hardwareModelName))

        #expect {
            try MacOSVMBundle(url: directory)
        } throws: { error in
            (error as? ContainerizationError)?.code == .invalidState && "\(error)".contains("is an incomplete instance; remove the container")
        }
    }

    @Test
    func testALinkedLayerWithoutAnOverlayIsAnIncompleteInstance() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = directory.appendingPathComponent(MacOSVMBundle.diskImageName)
        try FileManager.default.removeItem(at: disk)
        try FileManager.default.createSymbolicLink(at: disk, withDestinationURL: directory.appendingPathComponent(MacOSVMBundle.hardwareModelName))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(MacOSVMBundle.layerImageName), withDestinationURL: directory.appendingPathComponent(MacOSVMBundle.hardwareModelName))

        #expect {
            try MacOSVMBundle(url: directory)
        } throws: { error in
            (error as? ContainerizationError)?.code == .invalidState
        }
    }

    @Test
    func testAProvisionedUsernameThatIsNotAGuestUsernameIsNil() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try MacOSVMBundle(url: directory)

        try Data("ci\n-oProxyCommand=x".utf8).write(to: bundle.provisionedURL)
        #expect(bundle.provisionedUsername == nil)
        try Data("ci\n".utf8).write(to: bundle.provisionedURL)
        #expect(bundle.provisionedUsername == "ci")
    }

    @Test
    func testAgentVersionLineIsParsed() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try MacOSVMBundle(url: directory)
        #expect(bundle.agentVersionLine == nil)

        try Data("1 0.1.0\n".utf8).write(to: bundle.agentURL)

        #expect(bundle.agentVersionLine == AgentVersionLine(protocolNumber: 1, release: "0.1.0"))
    }
}

@Suite(.tags(.asif), .enabled(if: HostRequirement.asifSupported))
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

@Suite(.tags(.asif), .enabled(if: HostRequirement.asifSupported))
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

    @Test
    func testAFailureAfterTheLinkLeavesNeitherDestinationNorStaging() throws {
        let base = try makeBundle()
        let other = try makeBundle()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            for url in [base, other, destination] { try? FileManager.default.removeItem(at: url) }
        }
        let layerURL = FileManager.default.temporaryDirectory.appendingPathComponent("vm-layer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: layerURL) }
        let layer = try MacOSVMBundle(url: base).layerBundle(at: layerURL)
        // The base was built again after the layer: creating the overlay fails once the links exist.
        try FileManager.default.removeItem(at: layer.diskImageURL)
        try FileManager.default.createSymbolicLink(at: layer.diskImageURL, withDestinationURL: other.appendingPathComponent(MacOSVMBundle.diskImageName))

        #expect(throws: (any Error).self) { try layer.instance(at: destination) }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".parbake-new"))
    }

    @Test
    func testAnInstanceIsRefusedAsASource() throws {
        let base = try makeBundle()
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            for url in [base, first, second] { try? FileManager.default.removeItem(at: url) }
        }
        let instance = try MacOSVMBundle(url: base).instance(at: first)

        for build in [{ try instance.instance(at: second) }, { try instance.layerBundle(at: second) }] {
            #expect {
                try build()
            } throws: { error in
                (error as? ContainerizationError)?.code == .unsupported && "\(error)".contains("is a container's instance, not a bundle")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test
    func testAnInstanceWithoutItsOverlayNeverOpensTheBaseWritable() throws {
        let base = try makeBundle()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: destination)
        }
        let instance = try MacOSVMBundle(url: base).instance(at: destination)
        try FileManager.default.removeItem(at: instance.overlayImageURL)

        #expect {
            try instance.storageDeviceAttachment()
        } throws: { error in
            (error as? ContainerizationError)?.code == .invalidState
        }
        #expect(throws: ContainerizationError.self) { try MacOSVMBundle(url: destination) }
    }
}

@Suite(.tags(.asif), .enabled(if: HostRequirement.asifSupported))
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

    @Test
    func testResetOverlayRefreshesGuestKeyFromARebuiltBase() throws {
        let base = try makeASIFBundle()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: destination)
        }
        let source = try MacOSVMBundle(url: base)
        try Data("ci".utf8).write(to: source.provisionedURL)
        try Data("old-key".utf8).write(to: source.guestKeyURL)
        try Data("1 0.1.0".utf8).write(to: source.agentURL)
        let instance = try source.instance(at: destination)
        let identifier = try Data(contentsOf: instance.machineIdentifierURL)
        #expect(try Data(contentsOf: instance.guestKeyURL) == Data("old-key".utf8))

        // A rebuilt base brings a new key and hardware model, and no agent.
        try FileManager.default.removeItem(at: source.diskImageURL)
        try MacOSVMBundle.createDiskImage(at: source.diskImageURL, sizeInBytes: 1 << 30)
        try Data("new-key".utf8).write(to: source.guestKeyURL)
        try Data("new-model".utf8).write(to: source.hardwareModelURL)
        try FileManager.default.removeItem(at: source.agentURL)

        try instance.resetOverlay(from: source)

        #expect(try Data(contentsOf: instance.guestKeyURL) == Data("new-key".utf8))
        #expect(try Data(contentsOf: instance.hardwareModelURL) == Data("new-model".utf8))
        #expect(try Data(contentsOf: instance.provisionedURL) == Data("ci".utf8))
        #expect(!FileManager.default.fileExists(atPath: instance.agentURL.path))
        #expect(try Data(contentsOf: instance.machineIdentifierURL) == identifier)
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".parbake-reset"))
        _ = try instance.storageDeviceAttachment()
    }
}

@Suite(.tags(.asif), .enabled(if: HostRequirement.asifSupported))
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
