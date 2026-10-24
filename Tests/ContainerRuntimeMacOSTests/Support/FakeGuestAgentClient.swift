// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationOCI
import Foundation

@testable import RuntimeMacOS

/// A guest agent connection that records the calls it gets and answers from configured results.
///
/// It never waits in real time. `suspendReady()` and `suspendStart()` make the next
/// `waitUntilReady` and `startProcess` calls wait on the returned `Gate` until the test opens it.
actor FakeGuestAgentClient: GuestAgentClient {
    enum Call: Equatable, Sendable {
        case waitUntilReady(Duration)
        case createProcess(id: String)
        case startProcess(id: String)
        case wait(id: String)
        case signal(id: String, signal: Int32)
        case resize(id: String, columns: UInt32, rows: UInt32)
        case shutDown(provisionedUsername: String?, timeout: Duration)
        case close
    }

    struct Refused: Error {}

    /// The calls received so far, in order.
    private(set) var calls: [Call] = []
    /// The processes `createProcess` received, with their ids.
    private(set) var createdProcesses: [(id: String, process: ContainerizationOCI.Process)] = []
    /// The line `waitUntilReady` reports.
    var version = "1 0.0.0-dev"
    /// What `waitUntilReady` throws instead of answering.
    var readyError: (any Error)?
    /// The pid `startProcess` reports.
    var pid: Int32 = 100
    /// Whether the guest accepts the shutdown `shutDown` asks for.
    var acceptsShutdown = true
    /// The exits `wait(id:)` reports; a process without one makes `wait` throw `Refused`.
    var exits: [String: GuestExit] = [:]
    /// What every call but `waitUntilReady` throws when set; `close` and `shutDown` never throw.
    var failure: (any Error)?
    private var readyGate: Gate?
    private var startGate: Gate?

    init() {}

    /// Makes `waitUntilReady` wait until the returned gate opens.
    func suspendReady() -> Gate {
        let gate = Gate()
        readyGate = gate
        return gate
    }

    /// Makes `startProcess` wait until the returned gate opens.
    func suspendStart() -> Gate {
        let gate = Gate()
        startGate = gate
        return gate
    }

    func configure(
        version: String? = nil, readyError: (any Error)? = nil, pid: Int32? = nil, acceptsShutdown: Bool? = nil,
        exits: [String: GuestExit]? = nil, failure: (any Error)? = nil
    ) {
        if let version { self.version = version }
        if let readyError { self.readyError = readyError }
        if let pid { self.pid = pid }
        if let acceptsShutdown { self.acceptsShutdown = acceptsShutdown }
        if let exits { self.exits = exits }
        if let failure { self.failure = failure }
    }

    func waitUntilReady(timeout: Duration) async throws -> String {
        calls.append(.waitUntilReady(timeout))
        try await readyGate?.pass()
        if let readyError { throw readyError }
        return version
    }

    func createProcess(id: String, process: ContainerizationOCI.Process, stdio: [FileHandle?]) async throws {
        calls.append(.createProcess(id: id))
        createdProcesses.append((id, process))
        if let failure { throw failure }
    }

    func startProcess(id: String) async throws -> Int32 {
        calls.append(.startProcess(id: id))
        try await startGate?.pass()
        if let failure { throw failure }
        return pid
    }

    func wait(id: String) async throws -> GuestExit {
        calls.append(.wait(id: id))
        if let failure { throw failure }
        guard let exit = exits[id] else { throw Refused() }
        return exit
    }

    func signal(id: String, signal: Int32) async throws {
        calls.append(.signal(id: id, signal: signal))
        if let failure { throw failure }
    }

    func resize(id: String, columns: UInt32, rows: UInt32) async throws {
        calls.append(.resize(id: id, columns: columns, rows: rows))
        if let failure { throw failure }
    }

    func shutDown(provisionedUsername: String?, timeout: Duration, note: (String) -> Void) async -> Bool {
        calls.append(.shutDown(provisionedUsername: provisionedUsername, timeout: timeout))
        return acceptsShutdown
    }

    func close() async {
        calls.append(.close)
    }
}
