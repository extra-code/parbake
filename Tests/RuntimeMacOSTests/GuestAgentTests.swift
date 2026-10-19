// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationOCI
import Darwin
import Testing

@testable import RuntimeMacOS

struct GuestAgentTests {
    @Test(arguments: ["1", "1 0.52.0"])
    func testReadsTheProtocolNumber(version: String) {
        #expect(GuestAgent.protocolNumber(of: version) == 1)
    }

    @Test(arguments: ["", "agent", " 1"])
    func testAVersionWithoutAProtocolNumberHasNone(version: String) {
        #expect(GuestAgent.protocolNumber(of: version) == nil)
    }

    @Test
    func testSignalsUseDarwinNumbers() {
        #expect(GuestAgent.signalNumber("SIGTERM") == SIGTERM)
        #expect(GuestAgent.signalNumber("term") == SIGTERM)
        #expect(GuestAgent.signalNumber("15") == 15)
        #expect(GuestAgent.signalNumber("SIGUSR1") == 30)
        #expect(GuestAgent.signalNumber("SIGINFO") == SIGINFO)
    }

    @Test(arguments: ["", "SIGNOPE", "0", "99", "-9"])
    func testRejectsUnknownSignals(name: String) {
        #expect(GuestAgent.signalNumber(name) == nil)
    }
}

struct GuestUserTests {
    @Test
    func testTheInitUserBecomesTheProvisionedAccount() {
        let user = GuestUser.id(uid: 0, gid: 0).ociUser(provisionedUsername: "runner")
        #expect(user.username == "runner")
    }

    @Test
    func testTheInitUserStaysRootWithoutAProvisionedAccount() {
        let user = GuestUser.id(uid: 0, gid: 0).ociUser(provisionedUsername: nil)
        #expect(user.username.isEmpty)
        #expect(user.uid == 0)
    }

    @Test
    func testANamedUserPassesAsUsername() {
        let user = GuestUser.name("root").ociUser(provisionedUsername: "runner", additionalGids: [20])
        #expect(user.username == "root")
        #expect(user.additionalGids == [20])
    }

    @Test
    func testAnotherUIDPassesAsUID() {
        let user = GuestUser.id(uid: 502, gid: 20).ociUser(provisionedUsername: "runner")
        #expect(user.username.isEmpty)
        #expect(user.uid == 502)
        #expect(user.gid == 20)
    }
}
