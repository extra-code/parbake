// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Darwin
import GRPCCore

/// An agent failure with the gRPC status the host receives.
enum AgentError: Error {
    case invalidArgument(String)
    case notFound(String)
    case alreadyExists(String)
    case failedPrecondition(String)
    case unimplemented(String)
    case posix(String, Int32)

    var rpcError: RPCError {
        switch self {
        case .invalidArgument(let message):
            RPCError(code: .invalidArgument, message: message)
        case .notFound(let message):
            RPCError(code: .notFound, message: message)
        case .alreadyExists(let message):
            RPCError(code: .alreadyExists, message: message)
        case .failedPrecondition(let message):
            RPCError(code: .failedPrecondition, message: message)
        case .unimplemented(let what):
            RPCError(code: .unimplemented, message: "parbake-agent does not implement \(what)")
        case .posix(let call, let code):
            RPCError(code: .internalError, message: "\(call) failed: \(String(cString: strerror(code)))")
        }
    }
}
