// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Testing

@testable import RuntimeMacOS

struct RuntimeFailureTests {
    struct Row: Sendable {
        let failure: RuntimeFailure
        let contains: [String]
        let exitCode: Int32
        let code: ContainerizationError.Code
    }

    static let rows: [Row] = [
        Row(
            failure: .lockHeld(path: "/tmp/x.lock", holder: "parbake create"), contains: ["/tmp/x.lock", "another process", "parbake create"], exitCode: 75,
            code: .invalidState),
        Row(failure: .lockHeld(path: "/tmp/x.lock", holder: nil), contains: ["/tmp/x.lock", "another process"], exitCode: 75, code: .invalidState),
        Row(
            failure: .dhcpTimeout(macAddress: "aa:bb:cc:dd:ee:ff", seconds: 90, leaseFile: "/var/db/dhcpd_leases"),
            contains: ["aa:bb:cc:dd:ee:ff", "no DHCP lease", "/var/db/dhcpd_leases"], exitCode: 75, code: .timeout),
        Row(
            failure: .sshTimeout(username: "ci", address: "192.168.64.3", seconds: 60), contains: ["ci@192.168.64.3", "did not answer over SSH", "Remote Login"],
            exitCode: 75, code: .timeout),
        Row(
            failure: .agentTimeout(seconds: 180, label: "runtime-macos.readiness-timeout"), contains: ["180 seconds", "runtime-macos.readiness-timeout", "parbake agent-probe"],
            exitCode: 75,
            code: .timeout),
        Row(failure: .agentTimeout(seconds: 180, label: nil), contains: ["180 seconds", "parbake agent-probe"], exitCode: 75, code: .timeout),
        Row(
            failure: .keychainLocked(service: "svc"), contains: ["svc", "unlock the login keychain", "GUI session"], exitCode: 69, code: .invalidState),
        Row(failure: .keychainRefused(service: "svc", status: -25293), contains: ["svc", "-25293", "Keychain Access"], exitCode: 69, code: .invalidState),
        Row(
            failure: .bundleMissing(path: "/b", missing: "Disk.img"), contains: ["/b", "Disk.img", "parbake create"], exitCode: 66, code: .notFound),
        Row(failure: .bundleMissing(path: "/b", missing: nil), contains: ["/b", "parbake create"], exitCode: 66, code: .notFound),
        Row(
            failure: .restoreImageMissing(path: "/r.ipsw"), contains: ["/r.ipsw", "--restore-image"], exitCode: 66, code: .notFound),
        Row(failure: .vmLimitReached, contains: ["two macOS guests", "stop one", "reboot the host", "slot"], exitCode: 69, code: .unsupported),
    ]

    @Test(arguments: rows)
    func testDescriptionExitCodeAndMapping(row: Row) {
        let text = row.failure.description
        for part in row.contains {
            #expect(text.contains(part), "missing \(part) in \(text)")
        }
        #expect(row.failure.exitCode == row.exitCode)
        #expect(row.failure.containerizationCode == row.code)
    }

    @Test
    func testAgentTimeoutHasNoFraction() {
        #expect(!RuntimeFailure.agentTimeout(seconds: 180, label: "x").description.contains("180.0"))
    }

    @Test
    func testHolderIsAbsentWhenNil() {
        #expect(!RuntimeFailure.lockHeld(path: "/p", holder: nil).description.contains("()"))
    }
}
