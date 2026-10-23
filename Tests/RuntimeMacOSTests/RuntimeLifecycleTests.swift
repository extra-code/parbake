// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Darwin
import Testing

@testable import RuntimeMacOS

struct RuntimeLifecycleTests {
    enum State: CaseIterable, Sendable {
        case running
        case stopping
        case neither

        var isRunning: Bool { self == .running }
        var isStopping: Bool { self == .stopping }
    }

    static let notRunning = InitSignalAction.refuse("cannot kill: container is not running")

    static func notAStopSignal(_ signal: Int32) -> InitSignalAction {
        .refuse("signal \(signal) is not a stop signal; send TERM, INT, QUIT or KILL")
    }

    struct SignalRow: Sendable, CustomTestStringConvertible {
        let signal: Int32?
        let state: State
        let expected: InitSignalAction

        init(_ signal: Int32?, _ state: State, _ expected: InitSignalAction) {
            self.signal = signal
            self.state = state
            self.expected = expected
        }

        var testDescription: String { "signal \(signal) while \(state)" }
    }

    struct InputRow: Sendable {
        let mounts: Int
        let publishedPorts: Int
        let publishedSockets: Int
        let expected: String
    }

    static let signalTable: [SignalRow] = [
        SignalRow(SIGKILL, .running, .forceStop),
        SignalRow(SIGKILL, .stopping, .forceStop),
        SignalRow(SIGKILL, .neither, notRunning),
        SignalRow(SIGTERM, .running, .shutDown),
        SignalRow(SIGTERM, .stopping, .alreadyStopping),
        SignalRow(SIGTERM, .neither, notRunning),
        SignalRow(SIGINT, .running, .shutDown),
        SignalRow(SIGINT, .stopping, .alreadyStopping),
        SignalRow(SIGINT, .neither, notRunning),
        SignalRow(SIGQUIT, .running, .shutDown),
        SignalRow(SIGQUIT, .stopping, .alreadyStopping),
        SignalRow(SIGQUIT, .neither, notRunning),
        SignalRow(SIGHUP, .running, notAStopSignal(SIGHUP)),
        SignalRow(SIGHUP, .stopping, notAStopSignal(SIGHUP)),
        SignalRow(SIGHUP, .neither, notRunning),
        SignalRow(SIGUSR1, .running, notAStopSignal(SIGUSR1)),
        SignalRow(SIGUSR1, .stopping, notAStopSignal(SIGUSR1)),
        SignalRow(SIGUSR1, .neither, notRunning),
        SignalRow(nil, .running, .refuse("unknown signal BOGUS")),
        SignalRow(nil, .stopping, .refuse("unknown signal BOGUS")),
        SignalRow(nil, .neither, notRunning),
    ]

    @Test(arguments: State.allCases)
    func testRefusalCodeIsInvalidStateOnlyWhenNeitherRunningNorStopping(state: State) {
        let expected: ContainerizationError.Code = state == .neither ? .invalidState : .invalidArgument
        #expect(RuntimeLifecycle.refusalCode(isRunning: state.isRunning, isStopping: state.isStopping) == expected)
    }

    @Test
    func testGuestLossTimeoutIsTheShutdownFloor() {
        #expect(RuntimeLifecycle.guestLossTimeout == .seconds(60))
    }

    @Test(arguments: signalTable)
    func testSignalTable(row: SignalRow) {
        #expect(RuntimeLifecycle.initSignalAction(signal: row.signal, name: "BOGUS", isRunning: row.state.isRunning, isStopping: row.state.isStopping) == row.expected)
    }

    @Test
    func testSignalTableCoversEverySignalInEveryState() {
        let signals: [Int32?] = [SIGKILL, SIGTERM, SIGINT, SIGQUIT, SIGHUP, SIGUSR1, nil]
        for signal in signals {
            for state in State.allCases {
                #expect(Self.signalTable.contains { $0.signal == signal && $0.state == state })
            }
        }
        #expect(Self.signalTable.count == signals.count * State.allCases.count)
    }

    @Test
    func testRefusalOfAnotherSignalNamesTheSignalNumber() {
        #expect(
            RuntimeLifecycle.initSignalAction(signal: SIGHUP, isRunning: true, isStopping: false)
                == .refuse("signal 1 is not a stop signal; send TERM, INT, QUIT or KILL"))
    }

    @Test
    func testLostProcessMessageWithAnExitCode() {
        #expect(
            RuntimeLifecycle.lostProcessMessage(processID: "p1", guestExitCode: 3)
                == "the macOS guest stopped with exit code 3 while process p1 ran; the process has no exit code")
    }

    @Test
    func testLostProcessMessageWithANegativeExitCode() {
        #expect(
            RuntimeLifecycle.lostProcessMessage(processID: "job", guestExitCode: -1)
                == "the macOS guest stopped with exit code -1 while process job ran; the process has no exit code")
    }

    @Test
    func testLostProcessMessageWithoutAnExitCode() {
        #expect(
            RuntimeLifecycle.lostProcessMessage(processID: "p1", guestExitCode: nil)
                == "lost the guest agent's stream for process p1 while the guest kept running; its exit code is unknown")
    }

    @Test
    func testNoUnsupportedInputs() {
        #expect(RuntimeLifecycle.unsupportedInputs(mounts: 0, publishedPorts: 0, publishedSockets: 0) == nil)
    }

    @Test(arguments: [
        InputRow(mounts: 1, publishedPorts: 0, publishedSockets: 0, expected: "-v/--mount is not supported for macOS guests; remove the option"),
        InputRow(mounts: 0, publishedPorts: 1, publishedSockets: 0, expected: "-p/--publish is not supported for macOS guests; remove the option"),
        InputRow(mounts: 0, publishedPorts: 0, publishedSockets: 1, expected: "--publish-socket is not supported for macOS guests; remove the option"),
        InputRow(mounts: 2, publishedPorts: 3, publishedSockets: 0, expected: "-v/--mount and -p/--publish are not supported for macOS guests; remove the options"),
        InputRow(mounts: 1, publishedPorts: 0, publishedSockets: 4, expected: "-v/--mount and --publish-socket are not supported for macOS guests; remove the options"),
        InputRow(mounts: 0, publishedPorts: 1, publishedSockets: 1, expected: "-p/--publish and --publish-socket are not supported for macOS guests; remove the options"),
        InputRow(
            mounts: 1, publishedPorts: 2, publishedSockets: 3,
            expected: "-v/--mount, -p/--publish and --publish-socket are not supported for macOS guests; remove the options"),
    ])
    func testUnsupportedInputsNameEachNonzeroInput(row: InputRow) {
        #expect(RuntimeLifecycle.unsupportedInputs(mounts: row.mounts, publishedPorts: row.publishedPorts, publishedSockets: row.publishedSockets) == row.expected)
    }

    @Test(arguments: [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 1]])
    func testUnsupportedInputsNameOnlyTheNonzeroFlags(counts: [Int]) throws {
        let message = try #require(RuntimeLifecycle.unsupportedInputs(mounts: counts[0], publishedPorts: counts[1], publishedSockets: counts[2]))
        #expect(message.contains("-v/--mount") == (counts[0] > 0))
        #expect(message.contains("-p/--publish") == (counts[1] > 0))
        #expect(message.contains("--publish-socket") == (counts[2] > 0))
        #expect(message.contains("; remove the option"))
        #expect(!message.contains("README"))
    }

    @Test(arguments: [
        BundlePathError.notAbsolute("bundle"),
        .outsideRoots(path: "/tmp/VM.bundle", roots: ["/Users/u"]),
        .badRootsFile(path: "/Users/u/bundle-roots", reason: "line 1: x is not an absolute path"),
    ])
    func testBundlePathErrorMapsToInvalidArgument(error: BundlePathError) throws {
        let mapped = try #require(RuntimeLifecycle.containerizationError(from: error) as? ContainerizationError)
        #expect(mapped.code == .invalidArgument)
        #expect(mapped.message == error.description)
    }

    @Test(arguments: [
        RuntimeFailure.vmLimitReached,
        .bundleMissing(path: "/Users/u/VM.bundle", missing: nil),
        .lockHeld(path: "/Users/u/VM.bundle/AuxiliaryStorage", holder: nil),
        .agentTimeout(seconds: 180, label: "runtime-macos.readiness-timeout"),
    ])
    func testRuntimeFailureMapsToItsCode(failure: RuntimeFailure) throws {
        let mapped = try #require(RuntimeLifecycle.containerizationError(from: failure) as? ContainerizationError)
        #expect(mapped.code == failure.containerizationCode)
        #expect(mapped.message == failure.description)
    }

    @Test
    func testVMLimitReachedMapsToUnsupported() throws {
        let mapped = try #require(RuntimeLifecycle.containerizationError(from: RuntimeFailure.vmLimitReached) as? ContainerizationError)
        #expect(mapped.code == .unsupported)
        #expect(mapped.message.contains("two macOS guests"))
    }

    @Test
    func testOtherErrorsPassThrough() throws {
        let original = ContainerizationError(.timeout, message: "unchanged")
        let mapped = try #require(RuntimeLifecycle.containerizationError(from: original) as? ContainerizationError)
        #expect(mapped == original)
        #expect(mapped.message == "unchanged")
    }
}
