// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import NIOPosix
import ParbakeVersion

signal(SIGPIPE, SIG_IGN)

/// The vsock port containerization's agents serve on.
let defaultPort = 1024

ControllingTerminal.runIfRequested(CommandLine.arguments)

let arguments = CommandLine.arguments.dropFirst()
let port = arguments.first.flatMap(Int.init) ?? defaultPort

setenv(AgentVersionLine.variable, AgentVersionLine.current.description, 1)

// The gRPC server listens only on a Unix socket that no other account can open; the host reaches it
// through VsockFront, which admits the host's CID alone.
let socketPath =
    getuid() == 0
    ? "/var/run/parbake-agent.sock"
    : FileManager.default.temporaryDirectory.appendingPathComponent("parbake-agent-\(port).sock").path
unlink(socketPath)
umask(0o077)

let server = GRPCServer(
    transport: .http2NIOPosix(
        address: .unixDomainSocket(path: socketPath),
        transportSecurity: .plaintext,
        eventLoopGroup: MultiThreadedEventLoopGroup.singleton
    ),
    services: [SandboxService()]
)
let front = try VsockFront(port: UInt32(port), backend: socketPath)
front.start()
log("serving SandboxContext on vsock port \(port) for the host, through \(socketPath)")
try await withThrowingDiscardingTaskGroup { group in
    group.addTask { try await server.serve() }
    // The socket is created under umask 077; once it is bound, processes the agent starts get the
    // umask of a login session, else every file a job writes is readable by its owner alone.
    _ = try await server.listeningAddress
    umask(0o022)
}
