// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import parbake

struct GuestKeyTests {
    @Test
    func testCreatingTheGuestKeyWritesAPrivateAndAPublicKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guestkey-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("GuestKey")

        let created = try ParbakeTool.Provision.createGuestKey(at: key)

        #expect(FileManager.default.fileExists(atPath: key.path))
        #expect(FileManager.default.fileExists(atPath: key.appendingPathExtension("pub").path))
        #expect(created.hasPrefix("ssh-ed25519 "))
        #expect(try ParbakeTool.Provision.createGuestKey(at: key) == created)
    }
}
