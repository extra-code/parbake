// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import ContainerizationError
import RuntimeMacOS

enum ParbakeError: Error, CustomStringConvertible {
    case failure(RuntimeFailure)
    case scriptFailed(name: String, status: Int32)
    case runtime(String)

    var description: String {
        switch self {
        case .failure(let failure): failure.description
        case .scriptFailed(let name, let status): "\(name) exited with \(status)"
        case .runtime(let message): message
        }
    }
}

enum ParbakeExit {
    /// The exit code for an error: usage errors 64, scripts 3, known runtime failures by cause, any other error 1 (a ContainerizationError included).
    static func code(for error: any Error) -> Int32 {
        switch error {
        case let error as ParbakeError:
            switch error {
            case .failure(let failure): failure.exitCode
            case .scriptFailed: 3
            case .runtime: 1
            }
        case let failure as RuntimeFailure: failure.exitCode
        case is ValidationError: 64
        case is ContainerizationError: 1
        default: ParbakeTool.exitCode(for: error).rawValue
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let error as ParbakeError: error.description
        case let error as RuntimeFailure: error.description
        default: ParbakeTool.message(for: error)
        }
    }
}
