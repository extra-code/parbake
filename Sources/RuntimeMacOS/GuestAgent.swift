// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import GRPCCore
import NIOPosix
import ParbakeVersion

/// The runtime's side of the guest agent: readiness, and the processes the agent runs in the guest
/// with their standard streams copied to and from the host's file handles.
///
/// The agent speaks containerization's SandboxContext protocol on vsock port 1024; see
/// `docs/specs/spec_guest_agent.md`.
public actor GuestAgent {
    /// The first host vsock port for process streams.
    static let firstStreamPort: UInt32 = 0x1000_0000
    /// How long the agent gets to connect a process's streams after it started the process.
    static let streamTimeout: Duration = .seconds(30)

    private let virtualMachine: MacOSVirtualMachine?
    /// Reads the agent's version line, or nil while no agent answers; tests replace it.
    private let versionProbe: (@Sendable () async throws -> String?)?
    private var client: Vminitd?
    /// Counts connections, so a failed call drops only the connection it used.
    private var connection = 0
    private var nextPort = firstStreamPort
    private var processes: [String: AgentProcess] = [:]

    public init(virtualMachine: MacOSVirtualMachine) {
        self.virtualMachine = virtualMachine
        self.versionProbe = nil
    }

    /// An agent client without a virtual machine whose readiness check calls `versionProbe`.
    init(versionProbe: @escaping @Sendable () async throws -> String?) {
        self.virtualMachine = nil
        self.versionProbe = versionProbe
    }

    private func machine() throws -> MacOSVirtualMachine {
        guard let virtualMachine else {
            throw RuntimeFailure.internalError("the guest agent client has no virtual machine")
        }
        return virtualMachine
    }

    /// Whether an agent version line such as `1 0.52.0` names the protocol this runtime speaks.
    static func speaksProtocol(_ version: String) -> Bool {
        AgentVersionLine(version)?.protocolNumber == AgentVersionLine.protocolVersion
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
    /// Throws `RuntimeFailure.agentVersionMismatch` at once for an agent with another protocol, and
    /// `RuntimeFailure.agentTimeout` with no label when no agent answers within `timeout`.
    public func waitUntilReady(timeout: Duration) async throws -> String {
        let version = try await GuestReachability.poll(every: .seconds(1), timeout: timeout) { @Sendable [self] () async throws -> String? in
            let version: String?
            do {
                version = try await self.readVersion()
            } catch {
                // The agent is not up yet; dial again.
                return nil
            }
            guard let version else {
                return nil
            }
            guard Self.speaksProtocol(version) else {
                throw RuntimeFailure.agentVersionMismatch(agentVersion: version)
            }
            return version
        }
        guard let version else {
            throw RuntimeFailure.agentTimeout(seconds: Int(timeout.components.seconds), label: nil)
        }
        return version
    }

    private func readVersion() async throws -> String? {
        if let versionProbe {
            return try await versionProbe()
        }
        return try await call { try await $0.getenv(key: AgentVersionLine.variable) }
    }

    /// Records a process in the agent; `stdio` are the caller's standard input, output and error,
    /// each optional.
    public func createProcess(id: String, process: ContainerizationOCI.Process, stdio: [FileHandle?]) async throws {
        guard processes[id] == nil else {
            throw RuntimeFailure.exists("process \(id) already exists")
        }
        let listeners = try stdio.map { handle in
            try handle.map { _ in try machine().listen(onPort: allocatePort()) }
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
                throw RuntimeFailure.processLost(id: id, cause: "\(error)")
            }
            await process.streamsFinished()
            try? await self?.call { try await $0.deleteProcess(id: id, containerID: nil) }
            guard let status else {
                throw RuntimeFailure.processLost(id: id, cause: "\(CancellationError())")
            }
            return GuestExit(exitCode: status.exitCode, exitedAt: status.exitedAt)
        }
        return pid
    }

    /// Waits until the process has exited and its output has reached the caller's handles.
    public func wait(id: String) async throws -> GuestExit {
        guard let exit = try known(id).exit else {
            throw RuntimeFailure.invalidState("process \(id) is not started")
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
            throw RuntimeFailure.invalidState("process \(id) is not started")
        }
        return try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { try await exit.value.exitCode }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RuntimeFailure.timeout("\(process.args.joined(separator: " ")) did not finish within \(timeout)")
            }
            defer { group.cancelAll() }
            guard let code = try await group.next() else {
                throw CancellationError()
            }
            return code
        }
    }

    /// Runs `GuestCommands.shutdownArguments` as root, or with `sudo -n` as `provisionedUsername` when the agent does
    /// not run as root; returns whether the guest accepted it. `note` receives what happened.
    public func shutDown(provisionedUsername: String?, timeout: Duration, note: (String) -> Void) async -> Bool {
        var attempts = [ContainerizationOCI.Process(args: GuestCommands.shutdownArguments(asRoot: true), user: User(username: "root"))]
        if let provisionedUsername {
            attempts.append(
                ContainerizationOCI.Process(
                    args: GuestCommands.shutdownArguments(asRoot: false), user: User(username: provisionedUsername)))
        }
        for process in attempts {
            let user = process.user.username
            do {
                let code = try await run(process, timeout: timeout)
                guard code == 0 else {
                    note("guest refused the shutdown through the agent as \(user), exit code \(code)")
                    continue
                }
            } catch RuntimeFailure.processLost {
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
            throw RuntimeFailure.notFound("process \(id) does not exist")
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
            handle = try await machine().connect(toPort: Vminitd.port)
        } catch {
            throw RuntimeFailure.invalidState(
                causedMessage("the guest agent does not answer on vsock port \(Vminitd.port); install it with parbake agent install", cause: error))
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
        if let input = stdio[0], let connection = connections[0], Self.isRegularFile(input) {
            // A regular file never becomes readable at its end, so a readability handler would
            // never close the connection and the process would wait for more input forever.
            lock.withLock { stdinConnection = connection }
            copyFile(from: input, to: connection)
        } else if let input = stdio[0], let connection = connections[0] {
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

    private static func isRegularFile(_ handle: FileHandle) -> Bool {
        var status = stat()
        return fstat(handle.fileDescriptor, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
    }

    /// Copies the regular file `source` to the agent's stdin connection on its own thread, then
    /// closes the connection so the process reads the end of its input.
    private func copyFile(from source: FileHandle, to connection: FileHandle) {
        let thread = Thread { [weak self] in
            while let data = try? source.read(upToCount: 64 * 1024), !data.isEmpty {
                guard (try? connection.write(contentsOf: data)) != nil else {
                    break
                }
            }
            self?.closeStdin()
        }
        thread.start()
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
            // read(2) returns what is there; FileHandle.read(upToCount:) waits for the full count,
            // which holds interactive output back until the process ends.
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(source.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR {
                    continue
                }
                guard count > 0, (try? destination.write(contentsOf: Data(buffer[0..<count]))) != nil else {
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
