// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Darwin

/// What the runtime does with a signal sent to a container's init process.
public enum InitSignalAction: Equatable, Sendable {
    /// Stop the virtual machine at once, without a guest shutdown.
    case forceStop
    /// Request a guest shutdown.
    case shutDown
    /// A stop is already in progress; nothing more to do.
    case alreadyStopping
    /// Refuse the signal with this user-facing message.
    case refuse(String)
}

/// Lifecycle decisions of the runtime, as pure functions of the container's state.
public enum RuntimeLifecycle {
    /// How long the runtime waits for a lost guest to report its stop. Equal to the shutdown floor.
    public static let guestLossTimeout: Duration = .seconds(60)

    /// Maps a signal sent to the init process to an action. A container that is neither running nor
    /// stopping refuses every signal, known or not; while stopping, a stop already in progress takes
    /// precedence over a new shutdown request. `signal` is `nil` for a name the runtime does not know;
    /// `name` is that name as the client sent it.
    public static func initSignalAction(signal: Int32?, name: String = "", isRunning: Bool, isStopping: Bool) -> InitSignalAction {
        guard isRunning || isStopping else {
            return .refuse("cannot kill: container is not running")
        }
        guard let signal else {
            return .refuse("unknown signal \(name)")
        }
        switch signal {
        case SIGKILL:
            return .forceStop
        case SIGTERM, SIGINT, SIGQUIT:
            return isStopping ? .alreadyStopping : .shutDown
        default:
            return .refuse("signal \(signal) is not a stop signal; send TERM, INT, QUIT or KILL")
        }
    }

    /// The error code of a refused signal: a signal the container cannot take because it is neither
    /// running nor stopping is an invalid state; any other refusal is an invalid argument.
    public static func refusalCode(isRunning: Bool, isStopping: Bool) -> ContainerizationError.Code {
        isRunning || isStopping ? .invalidArgument : .invalidState
    }

    /// The message of a process whose exit code is lost: either the guest stopped (`guestExitCode` set)
    /// or the guest agent's stream ended while the guest kept running (`nil`).
    public static func lostProcessMessage(processID: String, guestExitCode: Int32?) -> String {
        if let guestExitCode {
            return "the macOS guest stopped with exit code \(guestExitCode) while process \(processID) ran; the process has no exit code"
        }
        return "lost the guest agent's stream for process \(processID) while the guest kept running; its exit code is unknown"
    }

    /// A refusal naming each requested input the runtime does not support, or `nil` when there is none.
    public static func unsupportedInputs(mounts: Int, publishedPorts: Int, publishedSockets: Int) -> String? {
        var flags: [String] = []
        if mounts > 0 { flags.append("-v/--mount") }
        if publishedPorts > 0 { flags.append("-p/--publish") }
        if publishedSockets > 0 { flags.append("--publish-socket") }
        guard !flags.isEmpty else { return nil }
        let list: String
        switch flags.count {
        case 1: list = flags[0]
        case 2: list = "\(flags[0]) and \(flags[1])"
        default: list = flags.dropLast().joined(separator: ", ") + " and " + flags[flags.count - 1]
        }
        let verb = flags.count == 1 ? "is" : "are"
        return "\(list) \(verb) not supported for macOS guests; remove the \(flags.count == 1 ? "option" : "options")"
    }

    /// The error the runtime reports to the client for `error`: a runtime failure becomes a
    /// `ContainerizationError` with its own code and its description; any other error passes through
    /// unchanged.
    public static func containerizationError(from error: any Error) -> any Error {
        switch error {
        case let failure as RuntimeFailure:
            ContainerizationError(failure.containerizationCode, message: failure.description)
        default:
            error
        }
    }
}
