// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RuntimeMacOS

struct LogSubsystemTests {
    @Test
    func testTheSubsystemNameIsThePluginName() {
        #expect(LogSubsystem.name == "container-runtime-macos")
    }

    @Test
    func testALoggerIsConstructibleForACategory() {
        let logger = LogSubsystem.logger(category: "parbake")
        logger.debug("log subsystem test")
    }
}
