// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Subprocess
import Synchronization

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

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
/// This is the one place the host side spawns a child process, through swift-subprocess.
public enum HostProcess {
    /// Where a standard output stream of the child goes.
    public enum Stream: Sendable {
        /// Collected into the result, without a size limit.
        case capture
        /// Shared with this process.
        case inherit
        /// Thrown away.
        case discard
    }

    /// SIGTERM, then SIGKILL two seconds later; used on a timeout and on task cancellation.
    private static let teardown: [TeardownStep] = [.gracefulShutDown(allowedDurationToNextStep: .seconds(2))]

    /// Runs `executable` without blocking a cooperative thread.
    ///
    /// `environment` of `nil` inherits this process's environment; a dictionary replaces it exactly.
    /// After `timeout`, measured on `ContinuousClock` like the two-second grace, the child gets SIGTERM,
    /// then SIGKILL two seconds later, and the result has `timedOut == true`.
    /// Cancelling the task stops the child the same way and returns its output with `timedOut == false`.
    /// - Throws: `RuntimeFailure.internalError` when the child cannot be started.
    public static func run(
        _ executable: URL, arguments: [String], environment: [String: String]? = nil, input: Data? = nil,
        stdout: Stream = .capture, stderr: Stream = .capture, timeout: Duration? = nil
    ) async throws(RuntimeFailure) -> ProcessOutput {
        try await withTaskGroup(of: Event.self) { group in
            group.addTask {
                .finished(
                    await launch(
                        executable, arguments: arguments, environment: environment, input: input, stdout: stdout,
                        stderr: stderr))
            }
            if let timeout {
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                        return .expired
                    } catch {
                        return .timerCancelled
                    }
                }
            }
            var timedOut = false
            var result: Result<ProcessOutput, RuntimeFailure> = .failure(.internalError("cannot run \(executable.path)"))
            for await event in group {
                switch event {
                case .finished(let finished):
                    result = finished
                    group.cancelAll()
                case .expired:
                    // Cancelling the launch runs `teardown` on the child.
                    timedOut = true
                    group.cancelAll()
                case .timerCancelled:
                    break
                }
            }
            return result.map { output in
                var output = output
                output.timedOut = timedOut
                return output
            }
        }.get()
    }

    private enum Event: Sendable {
        case finished(Result<ProcessOutput, RuntimeFailure>)
        case expired
        case timerCancelled
    }

    /// What the body of a run collected from the captured streams.
    private struct Collected: Sendable {
        var output = Data()
        var errorOutput = Data()
    }

    private static func launch(
        _ executable: URL, arguments: [String], environment: [String: String]?, input: Data?,
        stdout: Stream, stderr: Stream
    ) async -> Result<ProcessOutput, RuntimeFailure> {
        func failure(_ error: any Error) -> Result<ProcessOutput, RuntimeFailure> {
            .failure(.internalError("cannot run \(executable.path): \(error)"))
        }
        var options = PlatformOptions()
        options.teardownSequence = teardown
        let variables: Environment =
            environment.map { variables in
                .custom(Dictionary(uniqueKeysWithValues: variables.map { (Environment.Key(stringLiteral: $0.key), $0.value) }))
            } ?? .inherit
        let configuration = Configuration(
            executable: .path(FilePath(executable.path)), arguments: Arguments(arguments), environment: variables,
            platformOptions: options)

        let standardInput: StandardInput
        do {
            standardInput = try StandardInput(input)
        } catch {
            return failure(error)
        }
        do {
            let (status, collected) = try await spawn(configuration, input: standardInput, stdout: stdout, stderr: stderr)
            return .success(ProcessOutput(status: status, output: collected.output, errorOutput: collected.errorOutput))
        } catch {
            standardInput.abandon()
            return failure(error)
        }
    }

    /// Picks the Subprocess output type of each stream: a sequence the body drains, or a descriptor.
    private static func spawn(
        _ configuration: Configuration, input: StandardInput, stdout: Stream, stderr: Stream
    ) async throws -> (Int32, Collected) {
        switch (stdout, stderr) {
        case (.capture, .capture):
            let result = try await Subprocess.run(
                configuration, input: input.descriptor, output: .sequence, error: .sequence
            ) { execution in
                input.start()
                async let output = drain(execution.standardOutput)
                async let errorOutput = drain(execution.standardError)
                return await Collected(output: output, errorOutput: errorOutput)
            }
            return (status(result.terminationStatus), result.closureResult)
        case (.capture, let stderr):
            let result = try await Subprocess.run(
                configuration, input: input.descriptor, output: .sequence,
                error: try descriptor(stderr, standardError: true)
            ) { execution in
                input.start()
                return await Collected(output: drain(execution.standardOutput))
            }
            return (status(result.terminationStatus), result.closureResult)
        case (let stdout, .capture):
            let result = try await Subprocess.run(
                configuration, input: input.descriptor, output: try descriptor(stdout, standardError: false),
                error: .sequence
            ) { execution in
                input.start()
                return await Collected(errorOutput: drain(execution.standardError))
            }
            return (status(result.terminationStatus), result.closureResult)
        case (let stdout, let stderr):
            let result = try await Subprocess.run(
                configuration, input: input.descriptor, output: try descriptor(stdout, standardError: false),
                error: try descriptor(stderr, standardError: true)
            ) { _ in
                input.start()
                return Collected()
            }
            return (status(result.terminationStatus), result.closureResult)
        }
    }

    /// Reads `sequence` to its end; a failed or cancelled read ends the capture with what arrived.
    private static func drain(_ sequence: SubprocessOutputSequence) async -> Data {
        var data = Data()
        do {
            for try await buffer in sequence {
                buffer.withUnsafeBytes { data.append(contentsOf: $0) }
            }
        } catch {
            return data
        }
        return data
    }

    /// The descriptor an inherited or discarded stream writes to.
    private static func descriptor(_ stream: Stream, standardError: Bool) throws -> FileDescriptorOutput {
        switch stream {
        case .inherit:
            standardError ? .currentStandardError : .currentStandardOutput
        case .discard, .capture:
            .fileDescriptor(
                try FileDescriptor.open("/dev/null", .writeOnly, options: .closeOnExec), closeAfterSpawningProcess: true)
        }
    }

    private static func status(_ status: TerminationStatus) -> Int32 {
        switch status {
        // Darwin reports up to 24 bits of the value passed to exit(); `security` exits with -25300 for status 44.
        case .exited(let code): code & 0xFF
        case .signaled(let signal): 128 + signal
        }
    }

    /// The child's standard input: `/dev/null`, or a pipe whose write end a thread of its own fills.
    ///
    /// Subprocess's own input writer cannot be used: its pipe raises SIGPIPE here, and its failed write
    /// makes `run` throw, when the child exits without reading.
    private final class StandardInput: Sendable {
        let descriptor: FileDescriptorInput
        /// Taken exactly once, by `start` or `abandon`; a second close could hit a reused descriptor number.
        private let writeEnd: Mutex<FileDescriptor?>
        private let data: Data

        init(_ input: Data?) throws {
            guard let input else {
                descriptor = .fileDescriptor(
                    try FileDescriptor.open("/dev/null", .readOnly, options: .closeOnExec),
                    closeAfterSpawningProcess: true)
                writeEnd = Mutex(nil)
                data = Data()
                return
            }
            let pipe = try FileDescriptor.pipe()
            for end in [pipe.readEnd, pipe.writeEnd] { _ = fcntl(end.rawValue, F_SETFD, FD_CLOEXEC) }
            // Without it, a child that exits before reading everything kills this process with SIGPIPE.
            _ = fcntl(pipe.writeEnd.rawValue, F_SETNOSIGPIPE, 1)
            descriptor = .fileDescriptor(pipe.readEnd, closeAfterSpawningProcess: true)
            writeEnd = Mutex(pipe.writeEnd)
            data = input
        }

        /// Writes the input and closes the pipe; the child sees end of file after the last byte.
        ///
        /// The write blocks until the child reads or exits, so it runs on its own thread, never a cooperative one.
        func start() {
            guard let writeEnd = take() else { return }
            guard !data.isEmpty else {
                try? writeEnd.close()
                return
            }
            let data = data
            Thread {
                _ = try? data.withUnsafeBytes { try writeEnd.writeAll($0) }
                try? writeEnd.close()
            }.start()
        }

        /// Closes the write end unless `start` took it.
        func abandon() {
            try? take()?.close()
        }

        private func take() -> FileDescriptor? {
            writeEnd.withLock { end in
                defer { end = nil }
                return end
            }
        }
    }
}
