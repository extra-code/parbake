// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import ParbakeVersion

struct AgentVersionLineTests {
    @Test(
        arguments: [
            ("1", 1, nil),
            ("1 0.1.0\n", 1, "0.1.0"),
            ("1 0.52.0 x", 1, "0.52.0"),
            ("1  0.1.0", 1, nil),
        ] as [(String, Int, String?)])
    func testParsesTheLine(line: String, number: Int, release: String?) {
        let parsed = AgentVersionLine(line)
        #expect(parsed == AgentVersionLine(protocolNumber: number, release: release))
    }

    @Test(arguments: ["x 0.1.0", "", "+1"])
    func testRefusesALineWithoutAProtocolNumber(line: String) {
        #expect(AgentVersionLine(line) == nil)
    }

    @Test
    func testBoundsTheReleaseLength() {
        #expect(AgentVersionLine("1 " + String(repeating: "a", count: 33))?.release == nil)
        #expect(AgentVersionLine("1 " + String(repeating: "a", count: 32))?.release == String(repeating: "a", count: 32))
    }

    @Test
    func testCurrentLine() {
        #expect(AgentVersionLine.current.description == "1 \(Parbake.release)")
        #expect(AgentVersionLine.variable == "CONTAINER_RUNTIME_MACOS_AGENT")
    }

    /// A stamped release build holds `X.Y.Z`; every other build holds the sentinel.
    @Test
    func testReleaseIsTheSentinelOrAStampedVersion() {
        let release = Parbake.release
        let parts = release.split(separator: ".", omittingEmptySubsequences: false)
        let stamped = parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
        #expect(release == "0.0.0-dev" || stamped)
        #expect(AgentVersionLine("1 \(release)") == AgentVersionLine(protocolNumber: 1, release: release))
        #expect(AgentVersionLine.current.release == release)
    }

    @Test(.enabled(if: Parbake.release == "0.0.0-dev"))
    func testDevelopmentSentinelLine() {
        #expect(AgentVersionLine.current.description == "1 0.0.0-dev")
        #expect(AgentVersionLine("1 0.0.0-dev") == AgentVersionLine(protocolNumber: 1, release: "0.0.0-dev"))
    }
}
