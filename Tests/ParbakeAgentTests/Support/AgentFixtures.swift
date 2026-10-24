// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationOCI
import Darwin
import Foundation
import GRPCCore

@testable import parbake_agent

/// An OCI process that runs as the account running the tests, so no session bootstrap is needed.
func hostProcess(_ args: [String], terminal: Bool = false) -> ContainerizationOCI.Process {
    var process = ContainerizationOCI.Process(args: args, terminal: terminal)
    process.user.uid = getuid()
    process.cwd = "/"
    return process
}

/// A guest process of `args` with no stream ports.
func guestProcess(
    _ args: [String], id: String = "p", stdin: UInt32? = nil, stdout: UInt32? = nil, stderr: UInt32? = nil,
    connect: @escaping @Sendable (UInt32) throws -> Int32 = VsockConnection.toHost
) throws -> GuestProcess {
    try GuestProcess(id: id, process: hostProcess(args), stdin: stdin, stdout: stdout, stderr: stderr, connect: connect)
}

/// Stands in for the host's listeners: each connection to a port is a socket pair, the agent gets one
/// end and the test keeps the other. The test's ends close when `readAll` finishes with a port or when
/// the fixture is released, whichever comes first.
final class HostPorts: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [UInt32: Int32] = [:]

    deinit {
        for peer in peers.values {
            close(peer)
        }
    }

    /// The `connect` seam of the agent.
    var connect: @Sendable (UInt32) throws -> Int32 {
        { [self] port in
            var ends: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
                throw AgentError.posix("socketpair", errno)
            }
            lock.withLock {
                if let replaced = peers.updateValue(ends[1], forKey: port) {
                    close(replaced)
                }
            }
            return ends[0]
        }
    }

    /// The test's end of the connection to `port`; -1 when the agent did not connect.
    func peer(_ port: UInt32) -> Int32 {
        lock.withLock { peers[port] ?? -1 }
    }

    /// Reads from the connection to `port` until the agent closes it, then closes the test's end.
    func readAll(_ port: UInt32) -> String {
        let peer = peer(port)
        defer { closePeer(port) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(peer, &buffer, buffer.count)
            if count < 0 && errno == EINTR {
                continue
            }
            guard count > 0 else {
                break
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Closes the test's end of the connection to `port`, once.
    func closePeer(_ port: UInt32) {
        if let peer = lock.withLock({ peers.removeValue(forKey: port) }) {
            close(peer)
        }
    }

    /// Writes `text` to the agent over the connection to `port`.
    func send(_ text: String, to port: UInt32) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(peer(port), $0.baseAddress, $0.count) }
            guard written > 0 else {
                return
            }
            offset += written
        }
    }
}

/// A server context for calling a `SandboxService` handler directly.
func withServerContext<Result: Sendable>(_ body: (ServerContext) async throws -> Result) async throws -> Result {
    try await withServerContextRPCCancellationHandle { handle in
        let context = ServerContext(
            descriptor: MethodDescriptor(fullyQualifiedService: "test.Service", method: "Method"),
            remotePeer: "test:peer",
            localPeer: "test:agent",
            cancellation: handle
        )
        return try await body(context)
    }
}

/// The OCI spec JSON a `createProcess` request carries.
func specConfiguration(_ args: [String]) throws -> Data {
    try JSONEncoder().encode(ContainerizationOCI.Spec(process: hostProcess(args)))
}

/// The RPC code of the error `body` throws.
func rpcCode(_ body: () async throws -> Void) async -> RPCError.Code? {
    do {
        try await body()
        return nil
    } catch let error as RPCError {
        return error.code
    } catch {
        return nil
    }
}
