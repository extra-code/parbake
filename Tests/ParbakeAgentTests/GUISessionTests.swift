// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import parbake_agent

struct GUISessionTests {
    @Test
    func testAFalseProbeNamesTheAccount() async {
        await #expect(throws: AgentError.self) {
            try await GUISession.require(uid: 501, name: "ci", probe: { _ in false })
        }
        do {
            try await GUISession.require(uid: 501, name: "ci", probe: { _ in false })
        } catch AgentError.failedPrecondition(let message) {
            #expect(message.contains("account ci has no GUI session"))
            #expect(message.contains("log it in"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func testATrueProbeDoesNotThrow() async throws {
        try await GUISession.require(uid: 501, name: "ci", probe: { _ in true })
    }

    @Test
    func testUIDZeroIsNotProbed() async throws {
        nonisolated(unsafe) var probed = false
        try await GUISession.require(
            uid: 0, name: "root",
            probe: { _ in
                probed = true
                return false
            })
        #expect(!probed)
    }

    @Test
    func testTheProbeReceivesTheUID() async {
        nonisolated(unsafe) var seen: uid_t?
        try? await GUISession.require(
            uid: 777, name: "ci",
            probe: { uid in
                seen = uid
                return true
            })
        #expect(seen == 777)
    }
}
