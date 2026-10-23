// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Foundation
import Virtualization

/// Where a restore image comes from: a local file, or a URL that is downloaded into the cache.
public enum RestoreImageSource: Equatable, Sendable {
    case file(URL)
    case url(URL)

    /// A value starting with `http://` or `https://` is a URL; any other value is a path.
    public init(_ value: String) throws {
        let lowercased = value.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else {
            self = .file(URL(fileURLWithPath: (value as NSString).expandingTildeInPath))
            return
        }
        guard let url = URL(string: value), !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else {
            throw ContainerizationError(.invalidArgument, message: "\(value) is no restore image URL")
        }
        self = .url(url)
    }
}

/// Restore images downloaded once and reused. A `<file>.done` marker next to an image marks it
/// complete; an image without one is a partial download that the next fetch resumes.
public struct RestoreImageCache: Sendable {
    public static let completeSuffix = "done"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The cache file for `url`, named after its last path component.
    public func file(for url: URL) -> URL {
        directory.appendingPathComponent(url.lastPathComponent)
    }

    /// The lock that serializes downloads and pruning in this cache.
    public var lockFile: URL {
        directory.appendingPathComponent(".lock")
    }

    public func isComplete(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.appendingPathExtension(Self.completeSuffix).path)
    }

    /// Returns the cached image for `url`, downloading it first unless the cache holds it complete.
    ///
    /// A downloaded image is loaded with `verify` before it is marked complete; one that fails is
    /// deleted, so the next fetch downloads it again.
    public func fetch(
        _ url: URL,
        download: (URL, URL) async throws -> Void = RestoreImageCache.curl,
        verify: (URL) async throws -> Void = RestoreImageCache.load
    ) async throws -> URL {
        let file = file(for: url)
        if isComplete(file) {
            return file
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try FileLock.acquire(lockFile, wait: true, holder: "parbake download")
        defer { lock.release() }
        if isComplete(file) {
            return file
        }
        try await download(url, file)
        do {
            try await verify(file)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw ContainerizationError(
                .invalidState, message: "\(file.path) is no restore image Virtualization.framework can load; it was deleted, run create again",
                cause: error)
        }
        FileManager.default.createFile(atPath: file.appendingPathExtension(Self.completeSuffix).path, contents: nil)
        return file
    }

    /// Removes every other restore image, completion marker and partial download directly in the
    /// cache directory, and returns what it removed. Subdirectories and other files stay.
    @discardableResult
    public func prune(keeping kept: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try FileLock.acquire(lockFile, wait: true, holder: "parbake prune")
        defer { lock.release() }
        let keptNames: Set = [kept.lastPathComponent, kept.appendingPathExtension(Self.completeSuffix).lastPathComponent]
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        var removed: [URL] = []
        for entry in entries where !keptNames.contains(entry.lastPathComponent) {
            let name = entry.lastPathComponent
            guard name.hasSuffix(".ipsw") || name.hasSuffix(".ipsw.\(Self.completeSuffix)"),
                (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                continue
            }
            try FileManager.default.removeItem(at: entry)
            removed.append(entry)
        }
        return removed
    }

    /// Downloads `url` to `file` with curl, which resumes from a partial file and shows progress;
    /// URLSession keeps no resume data across runs.
    public static func curl(_ url: URL, to file: URL) async throws {
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["--fail", "--location", "--continue-at", "-", "--output", file.path, url.absoluteString]
        try curl.run()
        curl.waitUntilExit()
        guard curl.terminationStatus == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "downloading \(url.absoluteString) failed (curl exit status \(curl.terminationStatus)); run create again to resume")
        }
    }

    /// Loads `file` as a restore image.
    public static func load(_ file: URL) async throws {
        _ = try await VZMacOSRestoreImage.image(from: file)
    }
}

/// Builds a bundle at a target path, and with `replacing` swaps it in only once the build succeeded.
public enum BundleReplacement {
    public static let stagingSuffix = ".parbake-new"
    public static let retiredSuffix = ".parbake-old"

    public static func stagingURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + stagingSuffix)
    }

    public static func retiredURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + retiredSuffix)
    }

    /// Runs `build` with the path to build at.
    ///
    /// Without `replacing`, an existing target is refused and `build` writes to the target, which
    /// is removed again when `build` fails. With it, `build` writes next to the target; on success
    /// the target is swapped for the new bundle, and on failure the new bundle is removed and the
    /// target stays as it was.
    public static func build(at target: URL, replacing: Bool, _ build: (URL) async throws -> Void) async throws {
        let fileManager = FileManager.default
        guard replacing, fileManager.fileExists(atPath: target.path) else {
            guard !fileManager.fileExists(atPath: target.path) else {
                throw ContainerizationError(.exists, message: "\(target.path) already exists; pass --replace to rebuild it")
            }
            do {
                try await build(target)
            } catch {
                try? fileManager.removeItem(at: target)
                throw error
            }
            return
        }
        let staging = stagingURL(for: target)
        let retired = retiredURL(for: target)
        for leftover in [staging, retired] where fileManager.fileExists(atPath: leftover.path) {
            try fileManager.removeItem(at: leftover)
        }
        do {
            try await build(staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        try fileManager.moveItem(at: target, to: retired)
        do {
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.moveItem(at: retired, to: target)
            throw error
        }
        try fileManager.removeItem(at: retired)
    }

    /// The space the files under `url` take on disk, for the free-space check before a rebuild.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let entry as URL in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// The space available to a new bundle on the volume of `url`.
    public static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
