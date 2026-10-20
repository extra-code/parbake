// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import Virtualization

@testable import RuntimeMacOS

/// Bundles on a volume other than the instance's: the base lives on an HFS+ disk image that the
/// test attaches and detaches, so neither an APFS clone nor a cross-volume clone is possible.
@Suite(.serialized)
struct OtherVolumeTests {
    private func hdiutil(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Attaches an empty HFS+ volume, runs `body` with its mount point, and detaches it.
    private func withHFSVolume(_ body: (URL) throws -> Void) throws {
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-hfs-\(UUID()).dmg")
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-hfs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: image) }
        _ = try hdiutil(["create", "-quiet", "-size", "64m", "-fs", "HFS+", "-volname", "parbake-test", image.path])
        _ = try hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path])
        defer { _ = try? hdiutil(["detach", "-quiet", "-force", mountPoint.path]) }
        try body(mountPoint)
    }

    private func makeBundle(in directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("VM.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: bundle.appendingPathComponent(MacOSVMBundle.hardwareModelName))
        try Data(count: 1 << 20).write(to: bundle.appendingPathComponent(MacOSVMBundle.auxiliaryStorageName))
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.appendingPathComponent(MacOSVMBundle.machineIdentifierName))
        try MacOSVMBundle.createDiskImage(at: bundle.appendingPathComponent(MacOSVMBundle.diskImageName), sizeInBytes: 1 << 30)
        return bundle
    }

    @Test
    func testAnInstanceOfAnASIFBaseOnAnotherVolumeCopiesTheSmallFiles() throws {
        try withHFSVolume { volume in
            let base = try makeBundle(in: volume)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("vm-instance-\(UUID())")
            defer { try? FileManager.default.removeItem(at: destination) }

            let instance = try MacOSVMBundle(url: base).instance(at: destination)

            #expect(FileManager.default.contents(atPath: instance.auxiliaryStorageURL.path)?.count == 1 << 20)
            #expect(FileManager.default.fileExists(atPath: instance.overlayImageURL.path))
            _ = try instance.storageDeviceAttachment()
        }
    }
}
