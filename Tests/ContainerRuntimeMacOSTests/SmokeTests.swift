// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerXPC
import Testing

@testable import container_runtime_macos

struct SmokeTests {
    @Test
    func testAnXPCMessageCarriesItsRoute() {
        let message = XPCMessage(route: "ping")
        #expect(message.string(key: XPCMessage.routeKey) == "ping")
    }
}
