// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import NIOPosix

/// The protocol version of this agent; it changes only when the guest agent spec changes the wire contract.
let protocolVersion = 1
/// The environment variable the runtime reads through `Getenv` to recognise the agent.
let versionVariable = "CONTAINER_RUNTIME_MACOS_AGENT"
/// The vsock port containerization's agents serve on.
let defaultPort = 1024

ControllingTerminal.runIfRequested(CommandLine.arguments)

let arguments = CommandLine.arguments.dropFirst()
let port = arguments.first.flatMap(Int.init) ?? defaultPort

setenv(versionVariable, "\(protocolVersion)", 1)

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
try await server.serve()
