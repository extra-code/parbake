// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// The directories a bundle label may name, and the checks a bundle must pass.
public struct BundlePathPolicy: Sendable {
    public static func defaultRootsFile(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/container-runtime-macos/bundle-roots")
    }

    /// Canonical roots (symlinks resolved), home first.
    public let roots: [URL]

    private let uid: uid_t

    /// Reads `rootsFile` when it exists: one absolute path per line; blank lines and lines starting
    /// with `#` are skipped; a relative path, a missing directory or a file that is not owned by
    /// `uid` or is group- or world-writable throws RuntimeFailure.bundlePath.
    public init(home: URL, rootsFile: URL? = nil, uid: uid_t = getuid()) throws {
        self.uid = uid
        var roots = [Self.canonical(home.path) ?? home.resolvingSymlinksInPath().path]
        let file = (rootsFile ?? Self.defaultRootsFile(home: home)).path
        var info = stat()
        if stat(file, &info) == 0 {
            if info.st_uid != uid {
                throw RuntimeFailure.bundlePath(.badRootsFile(path: file, reason: "the file is not owned by the current user"))
            }
            if info.st_mode & 0o022 != 0 {
                throw RuntimeFailure.bundlePath(.badRootsFile(path: file, reason: "the file is writable by other users; run chmod go-w on it"))
            }
            let text: String
            do {
                text = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                throw RuntimeFailure.bundlePath(.badRootsFile(path: file, reason: "the file cannot be read: \(error.localizedDescription)"))
            }
            for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard line.hasPrefix("/"), !line.contains("\0") else {
                    throw RuntimeFailure.bundlePath(.badRootsFile(path: file, reason: "line \(index + 1): \(line) is not an absolute path"))
                }
                guard let resolved = Self.canonical(line) else {
                    throw RuntimeFailure.bundlePath(.badRootsFile(path: file, reason: "line \(index + 1): \(line) does not exist"))
                }
                var dir = stat()
                guard stat(resolved, &dir) == 0, dir.st_mode & S_IFMT == S_IFDIR else {
                    throw RuntimeFailure.bundlePath(.badRootsFile(path: file, reason: "line \(index + 1): \(line) is not a directory"))
                }
                if !roots.contains(resolved) { roots.append(resolved) }
            }
        }
        self.roots = roots.map { URL(fileURLWithPath: $0) }
    }

    /// Returns the canonical bundle URL or throws.
    public func validate(_ label: String) throws -> URL {
        guard label.hasPrefix("/"), !label.contains("\0") else { throw RuntimeFailure.bundlePath(.notAbsolute(label)) }
        guard let path = Self.canonical(label) else { throw RuntimeFailure.bundleMissing(path: label, missing: nil) }
        guard isUnderRoot(path) else { throw RuntimeFailure.bundlePath(.outsideRoots(path: path, roots: roots.map(\.path))) }
        try checkOwnerAndMode(path, followLinks: true)
        var names = MacOSVMBundle.fileNames
        names += [MacOSVMBundle.overlayImageName, MacOSVMBundle.layerImageName, MacOSVMBundle.provisionedName, MacOSVMBundle.guestKeyName, MacOSVMBundle.agentName]
        for name in names {
            let file = path + "/" + name
            var info = stat()
            guard lstat(file, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFLNK {
                guard let target = Self.canonical(file), isUnderRoot(target) else {
                    throw RuntimeFailure.bundlePath(
                        .linkOutsideRoots(file: file, target: Self.canonical(file) ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: file)) ?? ""))
                }
                try checkOwnerAndMode(target, followLinks: true)
            } else {
                try checkOwnerAndMode(file, followLinks: false)
            }
        }
        return URL(fileURLWithPath: path)
    }

    private func isUnderRoot(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return roots.contains { root in
            let rootParts = root.path.split(separator: "/")
            return parts.count >= rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
        }
    }

    private func checkOwnerAndMode(_ path: String, followLinks: Bool) throws {
        var info = stat()
        let status = followLinks ? stat(path, &info) : lstat(path, &info)
        guard status == 0 else { throw RuntimeFailure.bundleMissing(path: path, missing: nil) }
        if info.st_uid != uid { throw RuntimeFailure.bundlePath(.wrongOwner(path: path)) }
        if info.st_mode & 0o022 != 0 { throw RuntimeFailure.bundlePath(.writableByOthers(path: path)) }
    }

    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
