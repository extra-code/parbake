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
        #expect(AgentVersionLine.current.description == "1 0.1.0")
        #expect(AgentVersionLine.variable == "CONTAINER_RUNTIME_MACOS_AGENT")
    }
}
