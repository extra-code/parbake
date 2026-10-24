// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Logging
import Testing
import os

import struct Logging.Logger

@testable import container_runtime_macos

struct OSLogHandlerTests {
    @Test
    func testRenderWithoutMetadataIsTheMessage() {
        #expect(OSLogHandler.render(message: "started", metadata: [:]) == "started")
    }

    @Test
    func testRenderAppendsMetadataSortedByKey() {
        let metadata: Logger.Metadata = ["zone": "b", "alpha": "1", "mid": .stringConvertible(2)]

        #expect(OSLogHandler.render(message: "started", metadata: metadata) == "started [alpha=1] [mid=2] [zone=b]")
    }

    private static let osLogTypes: [(level: Logger.Level, type: OSLogType)] = [
        (.trace, .debug), (.debug, .debug), (.info, .info), (.notice, .info), (.warning, .default), (.error, .error), (.critical, .fault),
    ]

    @Test(arguments: osLogTypes)
    func testEveryLevelMapsToAnOSLogType(level: Logger.Level, expected: OSLogType) {
        #expect(OSLogHandler.osLogType(level) == expected)
    }

    @Test
    func testTheTableCoversEveryLevel() {
        #expect(Set(Self.osLogTypes.map(\.level)) == Set(Logger.Level.allCases))
    }
}
