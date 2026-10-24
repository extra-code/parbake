// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing

@testable import parbake_agent

struct GuestProcessTests {
    @Test
    func testStdoutReachesTheHostConnection() async throws {
        let ports = HostPorts()
        let process = try guestProcess(["/bin/echo", "hello"], stdout: 2, connect: ports.connect)
        _ = try await process.start()
        #expect(await process.wait().code == 0)
        #expect(ports.readAll(2) == "hello\n")
    }

    @Test
    func testStderrReachesItsOwnConnection() async throws {
        let ports = HostPorts()
        let process = try guestProcess(["/bin/sh", "-c", "echo out; echo err >&2"], stdout: 2, stderr: 3, connect: ports.connect)
        _ = try await process.start()
        _ = await process.wait()
        #expect(ports.readAll(2) == "out\n")
        #expect(ports.readAll(3) == "err\n")
    }

    @Test
    func testStdinFromTheHostReachesTheProcess() async throws {
        let ports = HostPorts()
        let process = try guestProcess(["/bin/cat"], stdin: 1, stdout: 2, connect: ports.connect)
        _ = try await process.start()
        ports.send("ping\n", to: 1)
        shutdown(ports.peer(1), SHUT_WR)
        #expect(await process.wait().code == 0)
        #expect(ports.readAll(2) == "ping\n")
    }

    @Test
    func testCloseStdinEndsCat() async throws {
        let ports = HostPorts()
        let process = try guestProcess(["/bin/cat"], stdin: 1, stdout: 2, connect: ports.connect)
        _ = try await process.start()
        process.closeStdin()
        #expect(await process.wait().code == 0)
    }

    @Test
    func testWithoutAStdinPortCatSeesEndOfInput() async throws {
        let process = try guestProcess(["/bin/cat"])
        _ = try await process.start()
        #expect(await process.wait().code == 0)
    }

    @Test
    func testAFailedConnectionFailsTheStart() async throws {
        struct Refused: Error {}
        let process = try guestProcess(["/usr/bin/true"], stdout: 2, connect: { _ in throw Refused() })
        await #expect(throws: Refused.self) { try await process.start() }
        #expect(!process.isRunning)
    }

    @Test
    func testResizeSetsTheTerminalWindowSize() throws {
        let terminal = try PseudoTerminal()
        defer {
            close(terminal.controller)
            close(terminal.device)
        }
        try PseudoTerminal.resize(controller: terminal.controller, columns: 132, rows: 43)
        var size = winsize()
        #expect(ioctl(terminal.device, TIOCGWINSZ, &size) == 0)
        #expect(size.ws_col == 132)
        #expect(size.ws_row == 43)
    }

    @Test
    func testResizeClampsToTheWindowSizeFields() throws {
        let terminal = try PseudoTerminal()
        defer {
            close(terminal.controller)
            close(terminal.device)
        }
        try PseudoTerminal.resize(controller: terminal.controller, columns: 1_000_000, rows: 0)
        var size = winsize()
        #expect(ioctl(terminal.device, TIOCGWINSZ, &size) == 0)
        #expect(size.ws_col == UInt16.max)
        #expect(size.ws_row == 0)
    }

    @Test
    func testResizeWithoutATerminalIsANoOp() async throws {
        let process = try guestProcess(["/usr/bin/true"])
        _ = try await process.start()
        _ = await process.wait()
        try process.resize(columns: 80, rows: 24)
    }
}
