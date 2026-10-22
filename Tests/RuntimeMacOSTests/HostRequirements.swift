// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

extension Tag {
    @Tag static var keychain: Self
    @Tag static var hdiutil: Self
    @Tag static var asif: Self
}

enum HostRequirement {
    /// `security show-keychain-info` on the default keychain exits 0.
    static let loginKeychainUsable: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["show-keychain-info"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    static let hdiutilAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")

    static let asifSupported = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
}

struct HostRequirementTests {
    @Test
    func testProbesReturn() {
        _ = HostRequirement.loginKeychainUsable
        _ = HostRequirement.hdiutilAvailable
        _ = HostRequirement.asifSupported
    }
}
