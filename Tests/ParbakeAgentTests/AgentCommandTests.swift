// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import parbake_agent

@Suite(.timeLimit(.minutes(1)))
struct AgentCommandTests {
    @Test
    func testCaptureReturnsStatusAndStandardOutput() async throws {
        let result = try #require(await AgentCommand.capture("/bin/echo", ["hello", "world"]))
        #expect(result.status == 0)
        #expect(result.output == "hello world\n")
    }

    @Test
    func testCaptureReturnsANonZeroStatus() async throws {
        let result = try #require(await AgentCommand.capture("/usr/bin/false", []))
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
    }

    @Test
    func testCaptureDiscardsStandardError() async throws {
        let result = try #require(await AgentCommand.capture("/bin/sh", ["-c", "echo out; echo err >&2"]))
        #expect(result.output == "out\n")
    }

    @Test
    func testCaptureReadsOutputLargerThanAPipeBuffer() async throws {
        let size = 1 << 20
        let result = try #require(await AgentCommand.capture("/usr/bin/head", ["-c", "\(size)", "/dev/zero"]))
        #expect(result.status == 0)
        #expect(result.output.utf8.count == size)
    }

    @Test
    func testCaptureOfAMissingExecutableIsNil() async {
        #expect(await AgentCommand.capture("/nonexistent/parbake-agent-test", []) == nil)
    }
}
