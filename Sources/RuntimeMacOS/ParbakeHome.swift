// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where parbake keeps bundles and restore images by default; `PARBAKE_HOME` moves both.
public struct ParbakeHome: Sendable {
    public let root: URL?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        root = environment["PARBAKE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    public var defaultBundle: URL {
        root?.appendingPathComponent("VM.bundle") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VM.bundle")
    }

    public var cache: URL {
        root?.appendingPathComponent("cache")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/parbake")
    }
}
