// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RuntimeMacOS

struct DHCPLeaseSelectionTests {
    private func block(address: String, lease: String) -> String {
        "{\n\tname=guest\n\tip_address=\(address)\n\thw_address=1,2:0:0:0:0:1\n\tlease=\(lease)\n}\n"
    }

    @Test
    func testTheNewestLeaseWins() {
        let leases = block(address: "192.168.64.5", lease: "0x6000") + block(address: "192.168.64.9", lease: "0x7000") + block(address: "192.168.64.7", lease: "0x5000")
        #expect(DHCPLeases.address(for: "02:00:00:00:00:01", in: leases) == "192.168.64.9")
    }

    @Test
    func testOnEqualTimesTheLaterEntryWins() {
        let leases = block(address: "192.168.64.5", lease: "0x6000") + block(address: "192.168.64.6", lease: "0x6000")
        #expect(DHCPLeases.address(for: "02:00:00:00:00:01", in: leases) == "192.168.64.6")
    }

    @Test
    func testALeaseWithoutATimeLosesToOneWithATime() {
        let bare = "{\n\tip_address=192.168.64.4\n\thw_address=1,2:0:0:0:0:1\n}\n"
        #expect(DHCPLeases.address(for: "02:00:00:00:00:01", in: bare + block(address: "192.168.64.8", lease: "0x1")) == "192.168.64.8")
        #expect(DHCPLeases.address(for: "02:00:00:00:00:01", in: bare) == "192.168.64.4")
    }

    @Test
    func testNoMatchingLeaseGivesNil() {
        #expect(DHCPLeases.address(for: "02:00:00:00:00:09", in: block(address: "192.168.64.5", lease: "0x1")) == nil)
    }
}
