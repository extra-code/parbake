// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

struct ParbakeHomeTests {
    @Test
    func testParbakeHomeMovesBundleAndCache() {
        let home = ParbakeHome(environment: ["PARBAKE_HOME": "/Volumes/External/parbake"])
        #expect(home.defaultBundle.path == "/Volumes/External/parbake/VM.bundle")
        #expect(home.cache.path == "/Volumes/External/parbake/cache")
    }

    @Test(arguments: [[:], ["PARBAKE_HOME": ""]])
    func testWithoutParbakeHomeTheDefaultsAreInTheHomeDirectory(environment: [String: String]) {
        let home = ParbakeHome(environment: environment)
        let user = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(home.defaultBundle.path == "\(user)/VM.bundle")
        #expect(home.cache.path == "\(user)/Library/Caches/parbake")
    }
}
