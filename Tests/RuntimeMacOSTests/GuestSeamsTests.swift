// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RuntimeMacOS

struct GuestSeamsTests {
    @Test
    func testTheRealTypesConformToTheSeams() {
        let machine: any GuestMachine.Type = MacOSVirtualMachine.self
        let agent: any GuestAgentClient.Type = GuestAgent.self
        #expect(String(describing: machine) == "MacOSVirtualMachine")
        #expect(String(describing: agent) == "GuestAgent")
    }

    @Test
    func testTheFakeRecordsCallsInOrder() async throws {
        let fake = FakeGuestMachine()
        let machine: any GuestMachine = fake
        fake.stopOn(.forceStop, exit: GuestExit(exitCode: 137))
        try await machine.requestStop()
        #expect(await machine.wait(timeout: .seconds(5)) == nil)
        try await machine.forceStop()
        #expect(machine.currentExit?.exitCode == 137)
        #expect(await machine.wait().exitCode == 137)
        #expect(fake.calls == [.requestStop, .waitWithTimeout(.seconds(5)), .forceStop, .wait])
    }
}
