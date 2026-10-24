// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import Foundation
import Testing

@testable import RuntimeMacOS
@testable import container_runtime_macos

struct KillRouteTests {
    @Test(arguments: ["TERM", "SIGTERM", "INT", "QUIT", ""])
    func testAStopSignalShutsTheGuestDownWithoutForcing(signal: String) async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        _ = try await client.kill(signal: signal)

        #expect(await fake.agent.calls.contains { if case .shutDown = $0 { true } else { false } })
        #expect(!fake.machine.calls.contains(.forceStop))
        #expect(!fake.machine.calls.contains(.requestStop))
        #expect(await service.currentState == .running)
    }

    @Test
    func testAStopSignalThatNothingAcceptsPressesThePowerButton() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        await fake.agent.configure(acceptsShutdown: false)
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.kill(signal: "TERM")

        #expect(fake.machine.calls.contains(.requestStop))
        #expect(!fake.machine.calls.contains(.forceStop))
    }

    @Test(arguments: ["KILL", "SIGKILL", "9"])
    func testKillStopsTheGuestForcibly(signal: String) async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.kill(signal: signal)

        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 1)
        #expect(await fake.agent.calls.isEmpty)
    }

    @Test
    func testAStopSignalWhileAStopRunsChangesNothing() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let gate = try await fake.suspendShellShutdown()
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let stopping = Task { try await client.stop() }
        await gate.untilArrived()
        _ = try await client.kill(signal: "TERM")
        let forcedByKill = fake.machine.calls.contains(.forceStop)
        gate.open()
        _ = try await stopping.value

        #expect(!forcedByKill)
        #expect(fake.calls.filter { if case .runShell = $0 { true } else { false } }.count == 1)
    }

    @Test(arguments: ["HUP", "USR1", "1"])
    func testASignalThatIsNoStopSignalIsRefusedNamingTheAllowedOnes(signal: String) async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.kill(signal: signal) }

        #expect(refusal?.code == .invalidArgument)
        #expect(refusal?.message.hasSuffix("is not a stop signal; send TERM, INT, QUIT or KILL") == true)
        #expect(!fake.machine.calls.contains(.forceStop))
        #expect(!fake.machine.calls.contains(.requestStop))
    }

    @Test
    func testHUPIsRefusedWithTheSignalNumber() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.kill(signal: "HUP") }

        #expect(refusal?.message == "signal 1 is not a stop signal; send TERM, INT, QUIT or KILL")
    }

    @Test
    func testAnUnknownSignalIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.kill(signal: "BOGUS") }

        #expect(refusal?.code == .invalidArgument)
        #expect(refusal?.message == "unknown signal BOGUS")
    }

    @Test
    func testKillOfAContainerThatIsNotRunningIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        _ = try await client.bootstrap()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.kill(signal: "KILL") }

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "cannot kill: container is not running")
    }

    @Test
    func testASignalToAnotherProcessReachesTheAgentAsANumber() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.kill("proc", signal: "HUP")

        #expect(await fake.agent.calls == [.signal(id: "proc", signal: SIGHUP)])
        #expect(!fake.machine.calls.contains(.forceStop))
    }

    @Test
    func testAnUnknownSignalToAnotherProcessIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.kill("proc", signal: "BOGUS") }

        #expect(refusal?.code == .invalidArgument)
        #expect(refusal?.message == "unknown signal BOGUS")
        #expect(await fake.agent.calls.isEmpty)
    }
}

struct ForcedStopTests {
    @Test
    func testKillDuringAStopCancelsTheShutdownRequestAndForceStopsOnce() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let (held, cancelled) = try await fake.holdShellUntilCancelled()
        fake.machine.stopOn(.forceStop, exit: GuestExit(exitCode: 137))
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        let stopping = Task { try await client.stop() }
        await held.untilArrived()
        _ = try await client.kill(signal: "KILL")
        await cancelled.untilArrived()
        _ = try await stopping.value

        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 1)
        #expect(!fake.machine.calls.contains(.requestStop))
        #expect(await service.currentState == .stopped)
        #expect(try await client.state().status == .stopped)
    }

    @Test
    func testAShutdownRequestThatEndsAcceptedAfterTheForceStopChangesNothing() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let gate = try await fake.suspendShellShutdown()
        fake.machine.stopOn(.forceStop, exit: GuestExit(exitCode: 137))
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        let stopping = Task { try await client.stop() }
        await gate.untilArrived()
        _ = try await client.kill(signal: "KILL")
        _ = try await stopping.value

        #expect(fake.machine.calls.filter { $0 == .forceStop }.count == 1)
        #expect(!fake.machine.calls.contains(.requestStop))
        #expect(await service.currentState == .stopped)
    }

    @Test
    func testAGuestThatStopsDuringTheShutdownRequestNeedsNoForcedStop() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        try fake.provisionGuest()
        fake.setLease("192.168.64.9", for: fake.machine.macAddress)
        await fake.agent.configure(acceptsShutdown: false)
        let machine = fake.machine
        fake.answerShell { _ in
            machine.stop()
            return GuestShell.Result(status: 255, output: "", errorOutput: "connection closed")
        }
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        _ = try await client.stop()

        #expect(!machine.calls.contains(.forceStop))
        #expect(!machine.calls.contains(.requestStop))
        #expect(await service.currentState == .stopped)
    }

    @Test
    func testStoppingAGuestThatAlreadyStoppedForcesNothing() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()
        fake.machine.stop()

        _ = try await client.stop()

        #expect(!fake.machine.calls.contains(.forceStop))
        #expect(!fake.machine.calls.contains(.requestStop))
        #expect(await service.currentState == .stopped)
    }
}

struct StopLadderTests {
    private func waits(_ machine: FakeGuestMachine) -> [Duration] {
        machine.calls.compactMap { if case .waitWithTimeout(let duration) = $0 { duration } else { nil } }
    }

    @Test
    func testAnAcceptedShutdownGetsAtLeastSixtySecondsWhateverTheStopTimeout() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.machine.stopOn(.waitWithTimeout(.seconds(60)))
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.stop(timeoutInSeconds: 5)

        #expect(waits(fake.machine) == [.seconds(60)])
        #expect(!fake.machine.calls.contains(.requestStop))
        #expect(!fake.machine.calls.contains(.forceStop))
    }

    @Test
    func testALongerStopTimeoutIsKept() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.machine.stopOn(.waitWithTimeout(.seconds(90)))
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.stop(timeoutInSeconds: 90)

        #expect(waits(fake.machine) == [.seconds(90)])
    }

    @Test
    func testTheSSHRequestRunsTheGuardedShutdownWithTheStopTimeoutCappedAtSixtySeconds() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        try await fake.suspendShellShutdown().open()
        fake.machine.stopOn(.waitWithTimeout(.seconds(120)))
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.stop(timeoutInSeconds: 120)

        #expect(
            fake.calls.contains(.runShell(command: GuestCommands.shutdownIfAllowed, address: "192.168.64.9", timeout: .seconds(60))))
        #expect(waits(fake.machine) == [.seconds(120)])
    }

    @Test
    func testAGuestThatTakesNothingGetsThePowerButtonThenIsStoppedForcibly() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        await fake.agent.configure(acceptsShutdown: false)
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.stop(timeoutInSeconds: 5)

        let ladder = fake.machine.calls.filter { $0 != .start && $0 != .wait }
        #expect(ladder == [.requestStop, .waitWithTimeout(.seconds(5)), .forceStop])
    }

    @Test
    func testAnAcceptedShutdownThatHangsFallsBackToThePowerButtonThenForce() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.stop(timeoutInSeconds: 5)

        let ladder = fake.machine.calls.filter { $0 != .start && $0 != .wait }
        #expect(ladder == [.waitWithTimeout(.seconds(60)), .requestStop, .waitWithTimeout(.seconds(5)), .forceStop])
    }
}
