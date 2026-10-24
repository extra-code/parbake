// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Subprocess

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// Runs a host program for the agent and captures its output.
///
/// This is the one place the agent spawns a child process, through swift-subprocess.
enum AgentCommand {
    /// How long a program may run, measured on `ContinuousClock`; then it gets SIGTERM, and SIGKILL two seconds later.
    static let timeout: Duration = .seconds(30)

    /// Runs `executable` with `arguments` and returns its exit status, or 128 plus the signal number
    /// when a signal ended it, and its standard output; standard error is discarded.
    /// Nil when the program could not be started. A program still running after `timeout` is stopped
    /// and the status it ended with is returned.
    static func capture(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String)? {
        await withTaskGroup(of: Event.self) { group in
            group.addTask { .finished(await launch(executable, arguments)) }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .expired
                } catch {
                    return .timerCancelled
                }
            }
            var result: (status: Int32, output: String)?
            for await event in group {
                switch event {
                case .finished(let finished):
                    result = finished
                    group.cancelAll()
                case .expired:
                    // Cancelling the launch runs the teardown on the child.
                    group.cancelAll()
                case .timerCancelled:
                    break
                }
            }
            return result
        }
    }

    private enum Event: Sendable {
        case finished((status: Int32, output: String)?)
        case expired
        case timerCancelled
    }

    private static func launch(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String)? {
        var options = PlatformOptions()
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(2))]
        let configuration = Configuration(
            executable: .path(FilePath(executable)), arguments: Arguments(arguments), platformOptions: options)
        do {
            let result = try await Subprocess.run(configuration, input: .none, output: .sequence, error: .discarded) {
                execution in
                var data = Data()
                do {
                    for try await buffer in execution.standardOutput {
                        buffer.withUnsafeBytes { data.append(contentsOf: $0) }
                    }
                } catch {
                    return data
                }
                return data
            }
            let status: Int32 =
                switch result.terminationStatus {
                // Darwin reports up to 24 bits of the value passed to exit(); a shell sees only the low 8.
                case .exited(let code): code & 0xFF
                case .signaled(let signal): 128 + signal
                }
            return (status, String(decoding: result.closureResult, as: UTF8.self))
        } catch {
            return nil
        }
    }
}
