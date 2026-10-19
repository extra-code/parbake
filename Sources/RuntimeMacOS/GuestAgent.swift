// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import GRPCCore
import NIOPosix

/// The runtime's side of the guest agent: readiness, and the processes the agent runs in the guest
/// with their standard streams copied to and from the host's file handles.
///
/// The agent speaks containerization's SandboxContext protocol on vsock port 1024; see
/// `docs/specs/spec_guest_agent.md`.
public actor GuestAgent {
    /// The wire protocol this runtime speaks; the first field of the agent's version line.
    public static let protocolVersion = 1
    /// The agent environment variable whose value is the agent's version line.
    public static let versionVariable = "CONTAINER_RUNTIME_MACOS_AGENT"
    /// The first host vsock port for process streams.
    static let firstStreamPort: UInt32 = 0x1000_0000
    /// How long the agent gets to connect a process's streams after it started the process.
    static let streamTimeout: Duration = .seconds(30)

    /// The agent answered with a protocol this runtime does not speak.
    public struct VersionMismatch: Error, CustomStringConvertible {
        public let agentVersion: String

        public var description: String {
            "the guest agent reports version \"\(agentVersion)\", this runtime speaks protocol \(GuestAgent.protocolVersion); "
                + "update the agent with parbake agent install"
        }
    }

    /// The connection to the agent ended after the process started, so its exit is unknown; a
    /// shutdown, for example, ends the connection before it reports its exit.
    public struct ProcessLost: Error, CustomStringConvertible {
        public let id: String
        public let cause: any Error

        public var description: String { "lost process \(id) in the guest: \(cause)" }
    }

    private let virtualMachine: MacOSVirtualMachine
    private var client: Vminitd?
    /// Counts connections, so a failed call drops only the connection it used.
    private var connection = 0
    private var nextPort = firstStreamPort
    private var processes: [String: AgentProcess] = [:]

    public init(virtualMachine: MacOSVirtualMachine) {
        self.virtualMachine = virtualMachine
    }

    /// Returns the protocol number of an agent version line such as `1 0.52.0`, or nil when the
    /// line has none.
    public static func protocolNumber(of version: String) -> Int? {
        version.split(separator: " ", omittingEmptySubsequences: false).first.flatMap { Int($0) }
    }

    /// Darwin's signal numbers by name; several differ from Linux, SIGUSR1 is 30 and not 10.
    static let signals: [String: Int32] = [
        "HUP": SIGHUP, "INT": SIGINT, "QUIT": SIGQUIT, "ILL": SIGILL, "TRAP": SIGTRAP, "ABRT": SIGABRT,
        "EMT": SIGEMT, "FPE": SIGFPE, "KILL": SIGKILL, "BUS": SIGBUS, "SEGV": SIGSEGV, "SYS": SIGSYS,
        "PIPE": SIGPIPE, "ALRM": SIGALRM, "TERM": SIGTERM, "URG": SIGURG, "STOP": SIGSTOP, "TSTP": SIGTSTP,
        "CONT": SIGCONT, "CHLD": SIGCHLD, "TTIN": SIGTTIN, "TTOU": SIGTTOU, "IO": SIGIO, "XCPU": SIGXCPU,
        "XFSZ": SIGXFSZ, "VTALRM": SIGVTALRM, "PROF": SIGPROF, "WINCH": SIGWINCH, "INFO": SIGINFO,
        "USR1": SIGUSR1, "USR2": SIGUSR2,
    ]

    /// Returns the Darwin signal number for `name`, written as `SIGTERM`, `TERM` or `15`, or nil.
    public static func signalNumber(_ name: String) -> Int32? {
        var name = name.uppercased()
        if name.hasPrefix("SIG") {
            name.removeFirst(3)
        }
        if let number = Int32(name) {
            return (1..<NSIG).contains(number) ? number : nil
        }
        return signals[name]
    }

    /// Dials the agent once a second until it answers with this runtime's protocol and returns its
    /// version line.
    ///
    /// Throws `VersionMismatch` at once for an agent with another protocol, and a timeout error
    /// when no agent answers within `timeout`.
    public func waitUntilReady(timeout: Duration) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        var lastError: (any Error)?
        while ContinuousClock.now < deadline {
            do {
                let version = try await call { try await $0.getenv(key: Self.versionVariable) }
                guard Self.protocolNumber(of: version) == Self.protocolVersion else {
                    throw VersionMismatch(agentVersion: version)
                }
                return version
            } catch let error as VersionMismatch {
                throw error
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ContainerizationError(
            .timeout, message: "the guest agent did not answer within \(timeout)", cause: lastError)
    }

    /// Records a process in the agent; `stdio` are the caller's standard input, output and error,
    /// each optional.
    public func createProcess(id: String, process: ContainerizationOCI.Process, stdio: [FileHandle?]) async throws {
        guard processes[id] == nil else {
            throw ContainerizationError(.exists, message: "process \(id) already exists")
        }
        let listeners = try stdio.map { handle in
            try handle.map { _ in try virtualMachine.listen(onPort: allocatePort()) }
        }
        do {
            try await call {
                try await $0.createProcess(
                    id: id, containerID: nil, stdinPort: listeners[0]?.port, stdoutPort: listeners[1]?.port,
                    stderrPort: listeners[2]?.port, ociRuntimePath: nil, configuration: Spec(process: process), options: nil)
            }
        } catch {
            for listener in listeners {
                listener?.close()
            }
            throw error
        }
        processes[id] = AgentProcess(stdio: stdio, listeners: listeners, terminal: process.terminal)
    }

    /// Starts a created process and connects its streams; returns its PID in the guest.
    @discardableResult
    public func startProcess(id: String) async throws -> Int32 {
        let process = try known(id)
        let pid: Int32
        do {
            pid = try await call { try await $0.startProcess(id: id, containerID: nil) }
        } catch {
            process.closeListeners()
            processes[id] = nil
            try? await call { try await $0.deleteProcess(id: id, containerID: nil) }
            throw error
        }
        try await process.connectStreams(timeout: Self.streamTimeout)
        process.exit = Task { [weak self] in
            let status: ExitStatus?
            do {
                status = try await self?.call { try await $0.waitProcess(id: id, containerID: nil) }
            } catch {
                await process.streamsFinished()
                throw ProcessLost(id: id, cause: error)
            }
            await process.streamsFinished()
            try? await self?.call { try await $0.deleteProcess(id: id, containerID: nil) }
            guard let status else {
                throw ProcessLost(id: id, cause: CancellationError())
            }
            return GuestExit(exitCode: status.exitCode, exitedAt: status.exitedAt)
        }
        return pid
    }

    /// Waits until the process has exited and its output has reached the caller's handles.
    public func wait(id: String) async throws -> GuestExit {
        guard let exit = try known(id).exit else {
            throw ContainerizationError(.invalidState, message: "process \(id) is not started")
        }
        return try await exit.value
    }

    /// Sends `signal` to the process group of the process.
    public func signal(id: String, signal: Int32) async throws {
        _ = try known(id)
        try await call { try await $0.signalProcess(id: id, containerID: nil, signal: signal) }
    }

    /// Sets the terminal size of a process with a terminal; a process without one has nothing to resize.
    public func resize(id: String, columns: UInt32, rows: UInt32) async throws {
        guard try known(id).terminal else {
            return
        }
        try await call { try await $0.resizeProcess(id: id, containerID: nil, columns: columns, rows: rows) }
    }

    /// Runs `process` without streams and returns its exit code, or throws when it does not finish
    /// within `timeout`.
    public func run(_ process: ContainerizationOCI.Process, timeout: Duration) async throws -> Int32 {
        let id = "runtime-\(UUID().uuidString)"
        try await createProcess(id: id, process: process, stdio: [nil, nil, nil])
        try await startProcess(id: id)
        guard let exit = try known(id).exit else {
            throw ContainerizationError(.invalidState, message: "process \(id) is not started")
        }
        return try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { try await exit.value.exitCode }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ContainerizationError(.timeout, message: "\(process.args.joined(separator: " ")) did not finish within \(timeout)")
            }
            defer { group.cancelAll() }
            guard let code = try await group.next() else {
                throw CancellationError()
            }
            return code
        }
    }

    /// Runs `shutdown -h now` as root, or with `sudo -n` as `provisionedUsername` when the agent does
    /// not run as root; returns whether the guest accepted it. `note` receives what happened.
    public func shutDown(provisionedUsername: String?, timeout: Duration, note: (String) -> Void) async -> Bool {
        var attempts = [ContainerizationOCI.Process(args: ["/sbin/shutdown", "-h", "now"], user: User(username: "root"))]
        if let provisionedUsername {
            attempts.append(
                ContainerizationOCI.Process(
                    args: ["/usr/bin/sudo", "-n", "/sbin/shutdown", "-h", "now"], user: User(username: provisionedUsername)))
        }
        for process in attempts {
            let user = process.user.username
            do {
                let code = try await run(process, timeout: timeout)
                guard code == 0 else {
                    note("guest refused the shutdown through the agent as \(user), exit code \(code)")
                    continue
                }
            } catch is ProcessLost {
                // The guest ended the agent's connection while it shut down.
            } catch let error as RPCError where error.code == .failedPrecondition {
                note("guest agent cannot run the shutdown as \(user): \(error.message)")
                continue
            } catch {
                note("guest agent did not run the shutdown: \(error)")
                return false
            }
            note("guest accepted the shutdown through the agent as \(user)")
            return true
        }
        return false
    }

    /// Closes the connection to the agent; processes in the guest keep running.
    public func close() async {
        try? await client?.close()
        client = nil
    }

    private func known(_ id: String) throws -> AgentProcess {
        guard let process = processes[id] else {
            throw ContainerizationError(.notFound, message: "process \(id) does not exist")
        }
        return process
    }

    private func allocatePort() -> UInt32 {
        defer { nextPort &+= 1 }
        return nextPort
    }

    /// Calls the agent over the current connection, dialling it first when there is none; a call
    /// that fails because the connection is gone drops it, so the next call dials again.
    private func call<Result: Sendable>(_ body: @Sendable (Vminitd) async throws -> Result) async throws -> Result {
        let client = try await connected()
        let used = connection
        do {
            return try await body(client)
        } catch let error as RPCError where error.code == .unavailable {
            if used == connection, self.client != nil {
                self.client = nil
                try? await client.close()
            }
            throw error
        }
    }

    private func connected() async throws -> Vminitd {
        if let client {
            return client
        }
        let handle: FileHandle
        do {
            handle = try await virtualMachine.connect(toPort: Vminitd.port)
        } catch {
            throw ContainerizationError(
                .invalidState, message: "the guest agent does not answer on vsock port \(Vminitd.port); install it with parbake agent install",
                cause: error)
        }
        let client = try await Vminitd(connection: handle, group: MultiThreadedEventLoopGroup.singleton)
        self.client = client
        connection += 1
        return client
    }
}

/// A process the agent runs for the runtime, with the copies between its vsock streams and the
/// caller's file handles.
private final class AgentProcess: @unchecked Sendable {
    let terminal: Bool
    private let stdio: [FileHandle?]
    private let listeners: [VsockPortListener?]
    private let copies = DispatchGroup()
    /// Set once by `startProcess` on the agent actor and read there only.
    var exit: Task<GuestExit, any Error>?
    private let lock = NSLock()
    private var stdinConnection: FileHandle?

    init(stdio: [FileHandle?], listeners: [VsockPortListener?], terminal: Bool) {
        self.stdio = stdio
        self.listeners = listeners
        self.terminal = terminal
    }

    func closeListeners() {
        for listener in listeners {
            listener?.close()
        }
    }

    /// Accepts the agent's stream connections and starts copying.
    func connectStreams(timeout: Duration) async throws {
        defer { closeListeners() }
        var connections: [FileHandle?] = []
        for listener in listeners {
            connections.append(try await listener?.accept(timeout: timeout))
        }
        if let input = stdio[0], let connection = connections[0] {
            lock.withLock { stdinConnection = connection }
            input.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, (try? connection.write(contentsOf: data)) != nil else {
                    self?.closeStdin()
                    return
                }
            }
        }
        for index in 1...2 {
            if let output = stdio[index], let connection = connections[index] {
                copy(from: connection, to: output)
            }
        }
    }

    /// Returns once the process's output has reached the caller's handles, and stops reading its input.
    func streamsFinished() async {
        await withCheckedContinuation { cc in
            copies.notify(queue: .global()) { cc.resume() }
        }
        closeStdin()
    }

    private func closeStdin() {
        stdio[0]?.readabilityHandler = nil
        let connection = lock.withLock {
            defer { stdinConnection = nil }
            return stdinConnection
        }
        // Closing the connection is what tells the agent that the input ended.
        try? connection?.close()
    }

    /// Copies `source` to `destination` on its own thread until the agent closes `source`, then
    /// closes `destination` so the caller's reader sees the end of the output.
    private func copy(from source: FileHandle, to destination: FileHandle) {
        copies.enter()
        let thread = Thread { [copies] in
            while let data = try? source.read(upToCount: 64 * 1024), !data.isEmpty {
                guard (try? destination.write(contentsOf: data)) != nil else {
                    break
                }
            }
            try? source.close()
            try? destination.close()
            copies.leave()
        }
        thread.start()
    }
}
