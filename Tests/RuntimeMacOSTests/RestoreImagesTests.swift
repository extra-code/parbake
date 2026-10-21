// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

struct RestoreImageSourceTests {
    @Test(arguments: ["https://updates.cdn-apple.com/x/UniversalMac_27.0.1_26A434_Restore.ipsw", "HTTP://mirror.example/a.ipsw"])
    func testAnHTTPValueIsAURL(value: String) throws {
        guard case .url(let url) = try RestoreImageSource(value) else {
            Issue.record("\(value) was not taken as a URL")
            return
        }
        #expect(url.lastPathComponent.hasSuffix(".ipsw"))
    }

    @Test(arguments: ["/Volumes/External/parbake/cache/a.ipsw", "relative/a.ipsw", "~/Downloads/a.ipsw"])
    func testAnyOtherValueIsAPath(value: String) throws {
        guard case .file(let file) = try RestoreImageSource(value) else {
            Issue.record("\(value) was not taken as a path")
            return
        }
        #expect(file.isFileURL)
        #expect(!file.path.contains("~"))
    }
}

struct RestoreImageCacheTests {
    private func makeCache() throws -> RestoreImageCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-cache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RestoreImageCache(directory: directory)
    }

    private let url = URL(string: "https://mirror.example/UniversalMac_27.0.1_26A434_Restore.ipsw")!

    @Test
    func testACompleteImageIsReusedWithoutADownload() async throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let file = cache.file(for: url)
        try Data("image".utf8).write(to: file)
        FileManager.default.createFile(atPath: file.appendingPathExtension(RestoreImageCache.completeSuffix).path, contents: nil)

        let fetched = try await cache.fetch(url, download: { _, _ in Issue.record("downloaded a complete image") }, verify: { _ in })

        #expect(fetched == file)
    }

    @Test
    func testADownloadThatDoesNotLoadIsDeletedAndNotMarkedComplete() async throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let file = cache.file(for: url)

        await #expect(throws: (any Error).self) {
            try await cache.fetch(url, download: { _, destination in try Data("not an ipsw".utf8).write(to: destination) })
        }

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!cache.isComplete(file))
    }

    @Test
    func testAVerifiedDownloadIsMarkedComplete() async throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        let fetched = try await cache.fetch(url, download: { _, destination in try Data("image".utf8).write(to: destination) }, verify: { _ in })

        #expect(cache.isComplete(fetched))
    }

    @Test
    func testPruningKeepsTheUsedImageAndForeignFiles() throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let names = ["new.ipsw", "new.ipsw.done", "old.ipsw", "old.ipsw.done", "partial.ipsw", "notes.txt"]
        for name in names {
            try Data(name.utf8).write(to: cache.directory.appendingPathComponent(name))
        }
        let subdirectory = cache.directory.appendingPathComponent("keep.ipsw")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let removed = try cache.prune(keeping: cache.directory.appendingPathComponent("new.ipsw"))

        #expect(Set(removed.map(\.lastPathComponent)) == ["old.ipsw", "old.ipsw.done", "partial.ipsw"])
        let left = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        #expect(Set(left) == ["new.ipsw", "new.ipsw.done", "notes.txt", "keep.ipsw"])
    }
}

struct BundleReplacementTests {
    private struct BuildFailed: Error {}

    private func makeTarget() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-replace-\(UUID())")
        let target = parent.appendingPathComponent("VM.bundle")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("Disk.img"))
        return target
    }

    private func disk(of bundle: URL) throws -> String {
        String(decoding: try Data(contentsOf: bundle.appendingPathComponent("Disk.img")), as: UTF8.self)
    }

    @Test
    func testAnExistingBundleIsRefusedWithoutReplace() async throws {
        let target = try makeTarget()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        await #expect {
            try await BundleReplacement.build(at: target, replacing: false) { _ in Issue.record("built over an existing bundle") }
        } throws: { error in
            "\(error)".contains("--replace")
        }
        #expect(try disk(of: target) == "old")
    }

    @Test
    func testAFailedBuildLeavesTheBundleUnchanged() async throws {
        let target = try makeTarget()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        await #expect(throws: BuildFailed.self) {
            try await BundleReplacement.build(at: target, replacing: true) { path in
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try Data("half".utf8).write(to: path.appendingPathComponent("Disk.img"))
                throw BuildFailed()
            }
        }

        #expect(try disk(of: target) == "old")
        #expect(!FileManager.default.fileExists(atPath: BundleReplacement.stagingURL(for: target).path))
    }

    @Test
    func testAFailedFirstBuildLeavesNothingBehind() async throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-replace-\(UUID())/VM.bundle")
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        await #expect(throws: BuildFailed.self) {
            try await BundleReplacement.build(at: target, replacing: false) { path in
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                throw BuildFailed()
            }
        }

        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func testASuccessfulBuildTakesThePlaceOfTheBundle() async throws {
        let target = try makeTarget()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        // A leftover of an interrupted run is removed before the build.
        let staging = BundleReplacement.stagingURL(for: target)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        try await BundleReplacement.build(at: target, replacing: true) { path in
            #expect(path.standardizedFileURL.path == staging.standardizedFileURL.path)
            #expect(!FileManager.default.fileExists(atPath: path.path))
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("new".utf8).write(to: path.appendingPathComponent("Disk.img"))
        }

        #expect(try disk(of: target) == "new")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: BundleReplacement.retiredURL(for: target).path))
    }
}
