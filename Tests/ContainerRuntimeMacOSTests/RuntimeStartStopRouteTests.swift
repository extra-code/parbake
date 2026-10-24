// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import Foundation
import Logging
import Testing

@testable import RuntimeMacOS
@testable import container_runtime_macos

struct StartRouteTests {
    @Test
    func testStartBootsTheGuest() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        #expect(fake.machine.calls.first == .start)
        #expect(await service.currentState == .running)
        #expect(try await client.state().status == .running)
        #expect(await fake.agent.calls.isEmpty)
    }

    @Test
    func testStartWaitsForTheAgentOfABundleThatHasOne() async throws {
        let fake = try FakeRuntimeEnvironment(labels: [RuntimeService.readinessTimeoutLabel: "30"])
        defer { fake.cleanUp() }
        try fake.installAgent()
        let client = RouteClient(service: fake.makeService())

        try await client.bootstrapAndStart()

        #expect(await fake.agent.calls == [.waitUntilReady(.seconds(30))])
    }

    @Test
    func testAnAgentThatDoesNotAnswerFailsTheStartAndStopsTheGuest() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        try fake.installAgent()
        await fake.agent.configure(readyError: RuntimeFailure.agentTimeout(seconds: 5, label: nil))
        let client = RouteClient(service: fake.makeService())
        _ = try await client.bootstrap()

        let failure = await #expect(throws: ContainerizationError.self) { try await client.start() }

        #expect(failure?.code == .timeout)
        #expect(
            failure?.message
                == "the guest agent did not answer within 5 seconds; run `parbake agent-probe` to check it or raise the container's runtime-macos.readiness-timeout label."
        )
        #expect(fake.machine.calls.contains(.forceStop))
    }

    @Test
    func testAnAgentThatFailsOtherwiseFailsTheStartAsATimeout() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        try fake.installAgent()
        await fake.agent.configure(readyError: RuntimeFailure.agentVersionMismatch(agentVersion: "9 1.0.0"))
        let client = RouteClient(service: fake.makeService())
        _ = try await client.bootstrap()

        let failure = await #expect(throws: ContainerizationError.self) { try await client.start() }

        #expect(failure?.code == .timeout)
        #expect(
            failure?.message
                == "the macOS guest started but its agent is not ready: \(RuntimeFailure.agentVersionMismatch(agentVersion: "9 1.0.0"))")
        #expect(fake.machine.calls.contains(.forceStop))
    }

    @Test
    func testTheVirtualMachineLimitMapsToUnsupportedAndLeavesTheContainerPrepared() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.machine.failStart(with: RuntimeFailure.vmLimitReached)
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        let failure = await #expect(throws: ContainerizationError.self) { try await client.start() }

        #expect(failure?.code == .unsupported)
        #expect(failure?.message == RuntimeFailure.vmLimitReached.description)
        #expect(await service.currentState == .prepared)
        fake.machine.failStart(with: nil)
        _ = try await client.start()
        #expect(await service.currentState == .running)
    }

    @Test
    func testStartingARunningContainerAgainIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.start() }

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "cannot start: container is running")
    }

    @Test
    func testStartingBeforeBootstrapIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.start() }

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "container is not bootstrapped")
    }

    @Test
    func testAnotherProcessStartsThroughTheAgent() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.start("proc")

        #expect(await fake.agent.calls == [.startProcess(id: "proc")])
    }

    @Test
    func testAnotherProcessCannotStartBeforeTheContainerRuns() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        _ = try await client.bootstrap()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.start("proc") }

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "container is not running")
    }
}

struct StartingStateTests {
    @Test
    func testASecondStartWhileTheGuestBootsIsRefusedAndOneGuestBoots() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let boot = fake.machine.suspendStart()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        let first = Task { try await client.start() }
        await boot.untilArrived()
        let second = await #expect(throws: ContainerizationError.self) { try await client.start() }
        let reported = try await client.state().status
        boot.open()
        _ = try await first.value

        #expect(second?.code == .invalidState)
        #expect(second?.message.contains("already starting") == true)
        #expect(reported == .stopped)
        #expect(fake.machine.calls.filter { $0 == .start }.count == 1)
        #expect(await service.currentState == .running)
    }

    @Test
    func testStopWhileTheGuestBootsForceStopsItAndEndsTheStartInterrupted() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let boot = fake.machine.suspendStart()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        fake.machine.stopOn(.forceStop)

        let start = Task { try await client.start() }
        await boot.untilArrived()
        _ = try await client.stop()
        let stateAfterStop = await service.currentState
        boot.open()
        let interrupted = await #expect(throws: ContainerizationError.self) { try await start.value }

        #expect(stateAfterStop == .stopped)
        #expect(interrupted?.code == .interrupted)
        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 1)
        #expect(!fake.machine.calls.contains(.wait))
        #expect(await service.currentState == .stopped)
        #expect(try await client.state().status == .stopped)
    }

    @Test
    func testAFailedForceStopWhileTheGuestBootsFailsTheStopAndLeavesTheContainerStopping() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.machine.failForceStop()
        let boot = fake.machine.suspendStart()
        let log = LogRecorder()
        let service = fake.makeService(log: log.logger)
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        let start = Task { try await client.start() }
        await boot.untilArrived()
        let failure = await #expect(throws: FakeGuestMachine.Refused.self) { try await client.stop() }
        let stateAfterStop = await service.currentState
        boot.open()
        let interrupted = await #expect(throws: ContainerizationError.self) { try await start.value }

        #expect(failure != nil)
        #expect(stateAfterStop == .stopping)
        #expect(log.entries.contains { $0.level == .error && $0.message == "could not stop the guest while it starts" })
        #expect(interrupted?.code == .interrupted)
        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 2)
        #expect(await service.currentState == .stopping)
    }

    @Test
    func testAStopThatFailedWhileTheGuestBootsEndsStoppedOnceTheBootReturnsAndTheGuestIsForceStopped() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.machine.failForceStop(times: 1)
        let boot = fake.machine.suspendStart()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        let start = Task { try await client.start() }
        await boot.untilArrived()
        await #expect(throws: FakeGuestMachine.Refused.self) { try await client.stop() }
        boot.open()
        let interrupted = await #expect(throws: ContainerizationError.self) { try await start.value }

        #expect(interrupted?.code == .interrupted)
        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 2)
        #expect(await service.currentState == .stopped)
    }

    @Test
    func testAStopThatFailedWhileTheGuestBootsEndsStoppedWhenTheBootFails() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.machine.failForceStop()
        let boot = fake.machine.suspendStart()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        let start = Task { try await client.start() }
        await boot.untilArrived()
        await #expect(throws: FakeGuestMachine.Refused.self) { try await client.stop() }
        boot.fail(RuntimeFailure.vmLimitReached)
        let interrupted = await #expect(throws: ContainerizationError.self) { try await start.value }

        #expect(interrupted?.code == .interrupted)
        #expect(await service.currentState == .stopped)
    }

    @Test
    func testABootThatReturnsAfterAStopIsForceStoppedAndClosesTheAgent() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let boot = fake.machine.suspendStart()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        let start = Task { try await client.start() }
        await boot.untilArrived()
        _ = try await client.stop()
        let forceStopsBeforeBootReturned = fake.machine.calls.filter { $0 == .forceStop }.count
        boot.open()
        let interrupted = await #expect(throws: ContainerizationError.self) { try await start.value }

        #expect(interrupted?.code == .interrupted)
        #expect(forceStopsBeforeBootReturned == 1)
        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 2)
        #expect(await fake.agent.calls.contains(.close))
        #expect(await service.currentState == .stopped)
    }

    @Test
    func testABootThatFailsAfterAStopIsStillInterrupted() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let boot = fake.machine.suspendStart()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        let start = Task { try await client.start() }
        await boot.untilArrived()
        _ = try await client.stop()
        boot.fail(RuntimeFailure.vmLimitReached)
        let interrupted = await #expect(throws: ContainerizationError.self) { try await start.value }

        #expect(interrupted?.code == .interrupted)
        #expect(await service.currentState == .stopped)
    }

    @Test
    func testShutdownWhileTheGuestBootsIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.provideNetwork(try .fake())
        let boot = fake.machine.suspendStart()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        let start = Task { try await client.start() }
        await boot.untilArrived()
        let refusal = await #expect(throws: ContainerizationError.self) { try await client.shutdown() }
        boot.open()
        _ = try await start.value

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "cannot shutdown: container is not stopped")
        #expect(fake.releasedNetworks == 0)
        #expect(await service.currentState == .running)
    }

    @Test
    func testKillWhileTheGuestBootsIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let boot = fake.machine.suspendStart()
        let client = RouteClient(service: fake.makeService())
        _ = try await client.bootstrap()

        let start = Task { try await client.start() }
        await boot.untilArrived()
        let refusal = await #expect(throws: ContainerizationError.self) { try await client.kill(signal: "KILL") }
        boot.open()
        _ = try await start.value

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "cannot kill: container is not running")
        #expect(!fake.machine.calls.contains(.forceStop))
    }

    @Test
    func testAStopWhileTheAgentIsNotYetReadyEndsTheStartInterrupted() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        try fake.installAgent()
        let ready = await fake.agent.suspendReady()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        let start = Task { try await client.start() }
        await ready.untilArrived()
        _ = try await client.stop()
        ready.open()
        let interrupted = await #expect(throws: ContainerizationError.self) { try await start.value }

        #expect(interrupted?.code == .interrupted)
    }

    @Test
    func testAStartWhoseAgentAnswersDuringAStopLeavesTheGuestToTheStop() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        try fake.installAgent()
        let shutdown = try await fake.suspendShellShutdown()
        let ready = await fake.agent.suspendReady()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        let start = Task { try await client.start() }
        await ready.untilArrived()
        let stopping = Task { try await client.stop() }
        await shutdown.untilArrived()
        ready.open()
        let interrupted = await #expect(throws: ContainerizationError.self) { try await start.value }
        let forceStopsWhileStopRuns = fake.machine.calls.filter { $0 == .forceStop }.count
        let agentClosedWhileStopRuns = await fake.agent.calls.contains(.close)
        shutdown.open()
        _ = try await stopping.value

        #expect(interrupted?.code == .interrupted)
        #expect(forceStopsWhileStopRuns == 0)
        #expect(!agentClosedWhileStopRuns)
        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 1)
        #expect(await service.currentState == .stopped)
    }
}

struct StopRouteTests {
    @Test
    func testStopOfAPreparedContainerMarksItStopped() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        _ = try await client.stop()

        #expect(await service.currentState == .stopped)
        #expect(fake.machine.calls.isEmpty)
        #expect(await fake.agent.calls.isEmpty)
    }

    @Test
    func testStopOfAContainerThatWasNeverBootstrappedChangesNothing() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let service = fake.makeService()
        let client = RouteClient(service: service)

        _ = try await client.stop()

        #expect(await service.currentState == .created)
    }

    @Test
    func testARejectedStopRequestIsLogged() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.machine.failRequestStop()
        fake.machine.stopOn(.forceStop)
        let log = LogRecorder()
        let client = RouteClient(service: fake.makeService(log: log.logger))
        try await client.bootstrapAndStart()

        _ = try await client.stop()

        #expect(log.entries.contains { $0.level == .warning && $0.message == "guest rejected the stop request" })
        #expect(fake.machine.calls.contains(.forceStop))
    }

    @Test
    func testAGuestThatNeitherShutsDownNorStopsFailsTheStopWithTheForcedStopsError() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.machine.failForceStop()
        let log = LogRecorder()
        let service = fake.makeService(log: log.logger)
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        let failure = await #expect(throws: FakeGuestMachine.Refused.self) { try await client.stop() }

        // The error is the forced stop's own, as at 12aa486: it is no ContainerizationError, and the
        // transport reports it as it does any other error.
        #expect(failure != nil)
        #expect("\(failure.map { String(describing: $0) } ?? "")" == "Refused()")
        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 1)
        #expect(log.entries.contains { $0.level == .error && $0.message == "could not stop the guest forcibly" })
        #expect(!log.entries.contains { $0.message.hasPrefix("guest did not shut down in time") })
        #expect(await service.currentState == .stopping)
    }

    @Test
    func testAForcedStopIsLoggedInThePastTense() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.machine.stopOn(.forceStop)
        let log = LogRecorder()
        let client = RouteClient(service: fake.makeService(log: log.logger))
        try await client.bootstrapAndStart()

        _ = try await client.stop()

        #expect(log.entries.contains { $0.level == .info && $0.message == "guest did not shut down in time, stopped it forcibly" })
    }

    @Test
    func testTwoConcurrentStopsForceStopOnceAndBothAnswer() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let gate = try await fake.suspendShellShutdown()
        fake.machine.stopOn(.forceStop, exit: GuestExit(exitCode: 137))
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        let first = Task { try await client.stop() }
        await gate.untilArrived()
        _ = try await client.stop()
        let stateWhileTheFirstRuns = await service.currentState
        gate.open()
        _ = try await first.value

        #expect(stateWhileTheFirstRuns == .stopping)
        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 1)
        #expect(await service.currentState == .stopped)
    }

    @Test
    func testKillDuringTheForcedStopOfAStopForceStopsAgainAndBothFinish() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let forceStops = fake.machine.suspendForceStop()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        let stopping = Task { try await client.stop() }
        await forceStops.untilArrived()
        let killing = Task { try await client.kill(signal: "KILL") }
        await forceStops.untilArrived(2)
        forceStops.open()
        _ = try await killing.value
        _ = try await stopping.value

        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 2)
        #expect(await service.currentState == .stopped)
        #expect(try await client.state().status == .stopped)
    }

    @Test
    func testAShutdownBeforeTheStopIsRefusedAndTheStopThenWorksAndAllowsTheShutdown() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.provideNetwork(try .fake())
        fake.machine.stopOn(.forceStop)
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.shutdown() }
        let callsAfterRefusal = fake.machine.calls
        _ = try await client.stop()
        _ = try await client.shutdown()

        #expect(refusal?.code == .invalidState)
        #expect(!callsAfterRefusal.contains(.forceStop) && !callsAfterRefusal.contains(.requestStop))
        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 1)
        #expect(fake.releasedNetworks == 1)
        #expect(await service.currentState == .shuttingDown)
    }

    @Test
    func testAShutdownDuringAStopSurvivesTheStopFinishing() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let gate = try await fake.suspendShellShutdown()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        let stopping = Task { try await client.stop() }
        await gate.untilArrived()
        _ = try await client.shutdown()
        gate.open()
        _ = try await stopping.value

        #expect(await service.currentState == .shuttingDown)
    }
}

/// Keeps every message logged through `logger`, for tests that check what the service logs.
private final class LogRecorder: @unchecked Sendable {
    struct Entry: Sendable {
        let level: Logger.Level
        let message: String
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []

    var entries: [Entry] { lock.withLock { recorded } }

    var logger: Logger {
        Logger(label: "recorded-runtime") { _ in Handler(recorder: self) }
    }

    fileprivate func append(_ entry: Entry) { lock.withLock { recorded.append(entry) } }

    private struct Handler: LogHandler {
        let recorder: LogRecorder
        var logLevel: Logger.Level = .trace
        var metadata = Logger.Metadata()

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            recorder.append(Entry(level: event.level, message: event.message.description))
        }
    }
}
