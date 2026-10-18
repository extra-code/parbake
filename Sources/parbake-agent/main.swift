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

let arguments = CommandLine.arguments.dropFirst()
let port = arguments.first.flatMap(Int.init) ?? defaultPort

setenv(versionVariable, "\(protocolVersion)", 1)

let server = GRPCServer(
    transport: .http2NIOPosix(
        address: .vsock(contextID: .any, port: .init(port)),
        transportSecurity: .plaintext,
        eventLoopGroup: MultiThreadedEventLoopGroup.singleton
    ),
    services: [SandboxService()]
)
FileHandle.standardError.write(Data("parbake-agent: serving SandboxContext on vsock port \(port)\n".utf8))
try await server.serve()
