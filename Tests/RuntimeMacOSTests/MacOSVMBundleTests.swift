// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

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

    @Test
    func testCloneCopiesEveryFile() throws {
        let directory = try makeBundleDirectory()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-clone-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: destination)
        }

        let clone = try MacOSVMBundle(url: directory).clone(to: destination)

        for name in MacOSVMBundle.fileNames {
            let data = try Data(contentsOf: clone.url.appendingPathComponent(name))
            #expect(data == Data(name.utf8))
        }
    }

    @Test
    func testCloneLeavesSourceUnchanged() throws {
        let directory = try makeBundleDirectory()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-clone-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: destination)
        }

        let clone = try MacOSVMBundle(url: directory).clone(to: destination)
        try Data("changed".utf8).write(to: clone.diskImageURL)

        let source = try Data(contentsOf: directory.appendingPathComponent(MacOSVMBundle.diskImageName))
        #expect(source == Data(MacOSVMBundle.diskImageName.utf8))
    }
}

struct DiskFormatTests {
    @Test(arguments: MacOSVMBundle.DiskFormat.allCases)
    func testCreatesASparseDiskImage(format: MacOSVMBundle.DiskFormat) throws {
        if format == .asif {
            guard #available(macOS 27, *) else { return }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vm-disk-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = directory.appendingPathComponent(MacOSVMBundle.diskImageName)

        try MacOSVMBundle.createDiskImage(at: disk, sizeInBytes: 64 << 30, format: format)

        let values = try disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        #expect((values.totalFileAllocatedSize ?? .max) < 64 << 20)
    }
}

struct InstanceTests {
    private func makeBundle(format: MacOSVMBundle.DiskFormat) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vm-base-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in MacOSVMBundle.fileNames where name != MacOSVMBundle.diskImageName {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        try VZMacMachineIdentifier().dataRepresentation.write(to: directory.appendingPathComponent(MacOSVMBundle.machineIdentifierName))
        try MacOSVMBundle.createDiskImage(
            at: directory.appendingPathComponent(MacOSVMBundle.diskImageName), sizeInBytes: 1 << 30, format: format)
        return directory
    }

    @Test
    func testAnASIFBaseGetsAnOverlayBoundToIt() throws {
        guard #available(macOS 27, *) else { return }
        let base = try makeBundle(format: .asif)
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
        guard #available(macOS 27, *) else { return }
        let base = try makeBundle(format: .asif)
        let other = try makeBundle(format: .asif)
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
    func testARawBaseIsCloned() throws {
        let base = try makeBundle(format: .raw)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: destination)
        }

        let instance = try MacOSVMBundle(url: base).instance(at: destination)

        #expect(!FileManager.default.fileExists(atPath: instance.overlayImageURL.path))
        let sourceIdentifier = try Data(contentsOf: base.appendingPathComponent(MacOSVMBundle.machineIdentifierName))
        let instanceIdentifier = try Data(contentsOf: instance.machineIdentifierURL)
        #expect(VZMacMachineIdentifier(dataRepresentation: instanceIdentifier) != nil)
        #expect(instanceIdentifier != sourceIdentifier)
        let attributes = try FileManager.default.attributesOfItem(atPath: instance.diskImageURL.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    }
}
