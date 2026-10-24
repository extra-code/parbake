// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
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
        #expect(Set(left) == [".lock", "new.ipsw", "new.ipsw.done", "notes.txt", "keep.ipsw"])
    }
}

struct BundleReplacementTests {
    private struct BuildFailed: Error {}

    fileprivate func makeTarget() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-replace-\(UUID())")
        let target = parent.appendingPathComponent("VM.bundle")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("Disk.img"))
        return target
    }

    fileprivate func disk(of bundle: URL) throws -> String {
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

struct FileLockTests {
    private func lockURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("parbake-lock-\(UUID()).parbake-lock")
    }

    @Test
    func testASecondAcquireNamesThePathAndTheHolder() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try FileLock.acquire(url, wait: false, holder: "parbake create")
        defer { first.release() }

        do {
            _ = try FileLock.acquire(url, wait: false, holder: "parbake create")
            Issue.record("a held lock was acquired twice")
        } catch let failure as RuntimeFailure {
            guard case .lockHeld(let path, let holder) = failure else {
                Issue.record("unexpected failure \(failure)")
                return
            }
            #expect(path == url.path)
            #expect(holder?.contains("parbake create") == true)
            #expect(holder?.contains("\(getpid())") == true)
            #expect("\(failure)".contains(url.path))
        }
    }

    @Test
    func testAcquiringSucceedsAfterReleaseAndReleaseRepeats() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try FileLock.acquire(url, wait: false, holder: "a")
        first.release()
        first.release()

        let second = try FileLock.acquire(url, wait: false, holder: "b")
        second.release()
    }

    @Test(.timeLimit(.minutes(1)))
    func testAWaitingAcquireTakesTheLockAfterTheHolderReleases() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try FileLock.acquire(url, wait: false, holder: "a")
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let acquired = Mutex(false)
        let waiter = Thread {
            started.signal()
            if let second = try? FileLock.acquire(url, wait: true, holder: "b") {
                acquired.withLock { $0 = true }
                second.release()
            }
            finished.signal()
        }
        waiter.start()
        started.wait()
        first.release()
        finished.wait()
        #expect(acquired.withLock { $0 })
    }

    @Test
    func testDroppingTheLockReleasesIt() throws {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try FileLock.acquire(url, wait: false, holder: "a")
        }
        try FileLock.acquire(url, wait: false, holder: "b").release()
    }
}

extension BundleReplacementTests {
    @Test
    func testAnExistingTargetIsKeptWhenNotReplacing() async throws {
        let target = try makeTarget()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        await #expect {
            try await BundleReplacement.build(at: target, replacing: false) { _ in Issue.record("built over an existing bundle") }
        } throws: { error in
            { if case .exists? = error as? RuntimeFailure { true } else { false } }()
        }
        #expect(try disk(of: target) == "old")
    }
}

struct RestoreImageCurlTests {
    @Test
    func testACurlFailureNamesTheStatusAndTheUrl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("curl-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("argv")
        let stub = directory.appendingPathComponent("curl")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(record.path)'\nexit 22\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let url = try #require(URL(string: "https://example.invalid/image.ipsw"))
        let file = directory.appendingPathComponent("image.ipsw")

        await #expect {
            try await RestoreImageCache.curl(url, to: file, executable: stub)
        } throws: { error in
            guard case .internalError(let message)? = error as? RuntimeFailure else { return false }
            return message == "downloading https://example.invalid/image.ipsw failed (curl exit status 22); run create again to resume"
        }
        let argv = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(argv == ["--fail", "--location", "--continue-at", "-", "--output", file.path, "https://example.invalid/image.ipsw"])
    }
}
