// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

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
