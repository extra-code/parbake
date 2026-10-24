// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

@Suite(.timeLimit(.minutes(1)))
struct HostProcessTests {
    private static let sh = URL(fileURLWithPath: "/bin/sh")

    private func shell(
        _ script: String, environment: [String: String]? = nil, input: Data? = nil, stdout: HostProcess.Stream = .capture,
        stderr: HostProcess.Stream = .capture, timeout: Duration? = nil
    ) throws -> ProcessOutput {
        try HostProcess.runBlocking(
            Self.sh, arguments: ["-c", script], environment: environment, input: input, stdout: stdout, stderr: stderr,
            timeout: timeout)
    }

    @Test
    func testTheExitStatusAndBothStreamsAreReturned() throws {
        let result = try shell("echo out; echo err >&2; exit 7")
        #expect(result.status == 7)
        #expect(String(decoding: result.output, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.errorOutput, as: UTF8.self) == "err\n")
        #expect(!result.timedOut)
    }

    @Test
    func testLargeOutputOnBothStreamsWithInputDoesNotDeadlock() throws {
        let input = Data(repeating: 0x61, count: 300_000)
        let result = try HostProcess.runBlocking(
            URL(fileURLWithPath: "/usr/bin/tee"), arguments: ["/dev/stderr"], input: input, timeout: .seconds(30))
        #expect(result.status == 0)
        #expect(result.output == input)
        #expect(result.errorOutput == input)
    }

    @Test
    func testInputTheChildIgnoresNeitherBlocksNorFails() throws {
        let input = Data(repeating: 0x62, count: 1_000_000)
        let result = try shell("echo done", input: input, timeout: .seconds(30))
        #expect(result.status == 0)
        #expect(String(decoding: result.output, as: UTF8.self) == "done\n")
    }

    @Test
    func testDiscardedStreamsAreNotCaptured() throws {
        let result = try shell("echo out; echo err >&2", stdout: .discard, stderr: .discard)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.errorOutput.isEmpty)
    }

    @Test
    func testAGivenEnvironmentReplacesTheInheritedOne() throws {
        let result = try HostProcess.runBlocking(
            URL(fileURLWithPath: "/usr/bin/env"), arguments: [], environment: ["PARBAKE_TEST": "1"])
        #expect(String(decoding: result.output, as: UTF8.self) == "PARBAKE_TEST=1\n")
    }

    @Test
    func testAnInheritedEnvironmentKeepsThePath() throws {
        let result = try shell("test -n \"$PATH\"")
        #expect(result.status == 0)
    }

    @Test
    func testATimeoutStopsTheChildWithSIGTERM() throws {
        let result = try shell("exec sleep 30", timeout: .milliseconds(200))
        #expect(result.timedOut)
        #expect(result.status == 128 + SIGTERM)
    }

    @Test
    func testATimeoutOfZeroStopsTheChild() throws {
        let result = try shell("exec sleep 30", timeout: .zero)
        #expect(result.timedOut)
        #expect(result.status == 128 + SIGTERM)
    }

    /// The timer can fire before `sh` installs the trap, so either signal may end the child; the deterministic
    /// kill case is the cancellation test below.
    @Test
    func testATimeoutStopsAChildThatIgnoresSIGTERM() throws {
        let result = try shell("trap '' TERM; exec sleep 30", timeout: .milliseconds(500))
        #expect(result.timedOut)
        #expect([128 + SIGKILL, 128 + SIGTERM].contains(result.status))
    }

    @Test
    func testCancellingTheTaskStopsTheChild() async throws {
        let task = Task {
            try await HostProcess.run(Self.sh, arguments: ["-c", "exec sleep 30"])
        }
        task.cancel()
        let result = try await task.value
        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGTERM)
    }

    @Test
    func testCancellingAfterTheChildIsUpStopsIt() async throws {
        let ready = try ReadyFIFO()
        defer { ready.remove() }
        let script = "echo ready > \(ready.shellPath); exec sleep 30"
        let task = Task { try await HostProcess.run(Self.sh, arguments: ["-c", script]) }
        await ready.wait()
        task.cancel()
        let result = try await task.value
        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGTERM)
    }

    @Test
    func testCancellingAChildThatIgnoresSIGTERMEndsItWithSIGKILL() async throws {
        let ready = try ReadyFIFO()
        defer { ready.remove() }
        let script = "trap '' TERM; echo ready > \(ready.shellPath); exec sleep 30"
        let task = Task { try await HostProcess.run(Self.sh, arguments: ["-c", script]) }
        await ready.wait()
        task.cancel()
        let result = try await task.value
        #expect(!result.timedOut)
        #expect(result.status == 128 + SIGKILL)
    }

    @Test
    func testASignalDeathReportsTheSignalAndNoTimeout() async throws {
        let blocking = try shell("kill -TERM $$")
        #expect(blocking.status == 128 + SIGTERM)
        #expect(!blocking.timedOut)
        let async = try await HostProcess.run(Self.sh, arguments: ["-c", "kill -TERM $$"])
        #expect(async.status == 128 + SIGTERM)
        #expect(!async.timedOut)
    }

    @Test
    func testEmptyInputGivesTheChildAnImmediateEndOfFile() throws {
        let result = try shell("cat", input: Data())
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test
    func testAChildThatExitsWithoutReadingLargeInputKeepsItsStatus() throws {
        let result = try shell("exit 3", input: Data(repeating: 0x62, count: 1_000_000))
        #expect(result.status == 3)
        #expect(!result.timedOut)
    }

    @Test
    func testBothStreamsOfAMegabyteEachWithInputDoNotDeadlock() throws {
        let input = Data(repeating: 0x61, count: 1 << 20)
        let result = try HostProcess.runBlocking(
            URL(fileURLWithPath: "/usr/bin/tee"), arguments: ["/dev/stderr"], input: input)
        #expect(result.status == 0)
        #expect(result.output == input)
        #expect(result.errorOutput == input)
    }

    @Test
    func testAnInheritedStreamIsNotCaptured() throws {
        let result = try shell("echo inherited", stdout: .inherit)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test
    func testRunReturnsTheOutputOfAFinishedChild() async throws {
        let result = try await HostProcess.run(Self.sh, arguments: ["-c", "echo hi"])
        #expect(result.status == 0)
        #expect(String(decoding: result.output, as: UTF8.self) == "hi\n")
    }

    @Test
    func testAMissingExecutableThrows() {
        #expect {
            try HostProcess.runBlocking(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
        } throws: { error in
            guard case RuntimeFailure.internalError(let message) = error else { return false }
            return message.hasPrefix("cannot run /nonexistent/tool: ")
        }
    }

    /// A named pipe a child writes to once it is set up; reading it blocks until then.
    private struct ReadyFIFO {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString)")
            guard mkfifo(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }

        var shellPath: String { "'\(url.path)'" }

        func wait() async {
            await withCheckedContinuation { continuation in
                Thread {
                    if let handle = try? FileHandle(forReadingFrom: url) {
                        _ = try? handle.readToEnd()
                        try? handle.close()
                    }
                    continuation.resume()
                }.start()
            }
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }
}
