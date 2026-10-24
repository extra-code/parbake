// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a finished host process produced.
public struct ProcessOutput: Sendable, Equatable {
    /// The exit status, or 128 plus the signal number when a signal ended the process.
    public var status: Int32
    public var output: Data
    public var errorOutput: Data
    /// Whether the process was stopped because `timeout` elapsed.
    public var timedOut: Bool

    public init(status: Int32, output: Data = Data(), errorOutput: Data = Data(), timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
        self.timedOut = timedOut
    }
}

/// Runs a host executable to completion and collects its output.
///
/// This is the one place the host side spawns a `Foundation.Process`.
public enum HostProcess {
    /// Where a standard output stream of the child goes.
    public enum Stream: Sendable {
        /// Collected into the result.
        case capture
        /// Shared with this process.
        case inherit
        /// Thrown away.
        case discard
    }

    /// Seconds between SIGTERM and SIGKILL.
    private static let killGrace = 2.0

    /// Runs `executable` and blocks the calling thread until it ends.
    ///
    /// `environment` of `nil` inherits this process's environment; a dictionary replaces it exactly.
    /// After `timeout` the child gets SIGTERM, then SIGKILL two seconds later.
    /// - Throws: `RuntimeFailure.internalError` when the child cannot be started.
    public static func runBlocking(
        _ executable: URL, arguments: [String], environment: [String: String]? = nil, input: Data? = nil,
        stdout: Stream = .capture, stderr: Stream = .capture, timeout: Duration? = nil
    ) throws(RuntimeFailure) -> ProcessOutput {
        try execute(
            executable, arguments: arguments, environment: environment, input: input, stdout: stdout, stderr: stderr,
            timeout: timeout, cancellation: Cancellation())
    }

    /// Runs `executable` without blocking a cooperative thread.
    ///
    /// Cancelling the task stops the child the same way a timeout does and returns its output with
    /// `timedOut == false`.
    public static func run(
        _ executable: URL, arguments: [String], environment: [String: String]? = nil, input: Data? = nil,
        stdout: Stream = .capture, stderr: Stream = .capture, timeout: Duration? = nil
    ) async throws(RuntimeFailure) -> ProcessOutput {
        let cancellation = Cancellation()
        let result: Result<ProcessOutput, RuntimeFailure> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Thread {
                    do throws(RuntimeFailure) {
                        continuation.resume(
                            returning: .success(
                                try execute(
                                    executable, arguments: arguments, environment: environment, input: input,
                                    stdout: stdout, stderr: stderr, timeout: timeout, cancellation: cancellation)))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try result.get()
    }

    /// Hands a cancellation to the process, whichever side gets there first.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func attach(_ process: Process) {
            lock.lock()
            self.process = process
            let already = cancelled
            lock.unlock()
            if already { HostProcess.stop(process, grace: HostProcess.killGrace, waiting: false) }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            if let process { HostProcess.stop(process, grace: HostProcess.killGrace, waiting: false) }
        }
    }

    private final class Captured: @unchecked Sendable {
        var output = Data()
        var errorOutput = Data()
    }

    private static func execute(
        _ executable: URL, arguments: [String], environment: [String: String]?, input: Data?,
        stdout: Stream, stderr: Stream, timeout: Duration?, cancellation: Cancellation
    ) throws(RuntimeFailure) -> ProcessOutput {
        // legacy: Foundation.Process until swift-subprocess replaces it; see docs/adr/adr_0014_one_runner_and_one_error_type_per_module.md
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let stdinPipe = input == nil ? nil : Pipe()
        let outputPipe = stdout == .capture ? Pipe() : nil
        let errorPipe = stderr == .capture ? Pipe() : nil
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        if let target = destination(stdout, pipe: outputPipe) { process.standardOutput = target }
        if let target = destination(stderr, pipe: errorPipe) { process.standardError = target }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw .internalError("cannot run \(executable.path): \(error.localizedDescription)")
        }
        cancellation.attach(process)

        // Each pipe has its own thread, so none fills while another is serviced.
        let captured = Captured()
        let threads = DispatchGroup()
        if let outputPipe {
            threads.enter()
            Thread {
                captured.output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                threads.leave()
            }.start()
        }
        if let errorPipe {
            threads.enter()
            Thread {
                captured.errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
                threads.leave()
            }.start()
        }
        if let stdinPipe, let input {
            let writer = stdinPipe.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            threads.enter()
            Thread {
                try? writer.write(contentsOf: input)
                try? writer.close()
                threads.leave()
            }.start()
        }

        var timedOut = false
        if let timeout, exited.wait(timeout: .now() + seconds(timeout)) == .timedOut {
            timedOut = true
            stop(process, grace: killGrace, waiting: true, exited: exited)
        } else if timeout == nil {
            exited.wait()
        }
        threads.wait()
        let status =
            process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
        return ProcessOutput(status: status, output: captured.output, errorOutput: captured.errorOutput, timedOut: timedOut)
    }

    private static func destination(_ stream: Stream, pipe: Pipe?) -> Any? {
        switch stream {
        case .capture: pipe
        case .inherit: nil
        case .discard: FileHandle.nullDevice
        }
    }

    /// SIGTERM now, SIGKILL after `grace` seconds if the process is still there.
    /// With `waiting`, blocks until `exited` signals; otherwise the kill is scheduled.
    private static func stop(_ process: Process, grace: Double, waiting: Bool, exited: DispatchSemaphore? = nil) {
        process.terminate()
        if waiting, let exited {
            if exited.wait(timeout: .now() + grace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
