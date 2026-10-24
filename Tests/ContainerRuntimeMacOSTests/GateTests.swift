// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Testing

struct GateTests {
    @Test
    func testHeldCallerPassesWhenTheGateOpens() async throws {
        let gate = Gate()
        let caller = Task { try await gate.pass() }
        await gate.untilArrived()

        gate.open()

        try await caller.value
        try await gate.pass()
        #expect(gate.arrivals == 2)
    }

    @Test
    func testFailingTheGateThrowsToHeldCallers() async {
        struct Refused: Error {}
        let gate = Gate()
        let caller = Task { try await gate.pass() }
        await gate.untilArrived()

        gate.fail(Refused())

        await #expect(throws: Refused.self) { try await caller.value }
    }

    @Test
    func testCancellingAHeldCallerThrowsCancellation() async {
        let gate = Gate()
        let caller = Task { try await gate.pass() }
        await gate.untilArrived()

        caller.cancel()

        await #expect(throws: CancellationError.self) { try await caller.value }
    }
}
