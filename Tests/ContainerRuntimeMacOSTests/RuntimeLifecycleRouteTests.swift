// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import Foundation
import Testing

@testable import RuntimeMacOS
@testable import container_runtime_macos

struct StateRouteTests {
    @Test
    func testACreatedContainerReportsStopped() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())

        let snapshot = try await client.state()

        #expect(snapshot.status == .stopped)
        #expect(snapshot.containers.isEmpty)
        #expect(snapshot.networks.isEmpty)
    }

    @Test
    func testAPreparedContainerReportsStopped() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        #expect(try await client.state().status == .stopped)
        #expect(await service.currentState == .prepared)
    }

    @Test
    func testARunningContainerReportsItsSnapshot() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.provideNetwork(try .fake())
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let snapshot = try await client.state()

        #expect(snapshot.status == .running)
        #expect(snapshot.networks.count == 1)
        #expect(snapshot.containers.map(\.status) == [.running])
        #expect(snapshot.containers.first?.startedDate == Date(timeIntervalSince1970: 1_000_000))
        #expect(snapshot.containers.first?.configuration.id == client.containerID)
    }

    @Test
    func testAStoppingContainerReportsStopping() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let gate = try await fake.suspendShellShutdown()
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        let stopping = Task { try await client.stop() }
        await gate.untilArrived()
        let snapshot = try await client.state()
        fake.machine.stop()
        gate.open()
        _ = try await stopping.value

        #expect(snapshot.status == .stopping)
        #expect(await service.currentState == .stopped)
    }

    @Test
    func testAStoppedContainerReportsStopped() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()
        _ = try await client.stop()

        #expect(try await client.state().status == .stopped)
        #expect(await service.currentState == .stopped)
    }

    @Test
    func testAContainerShuttingDownReportsStopped() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()
        _ = try await client.shutdown()

        #expect(try await client.state().status == .stopped)
        #expect(await service.currentState == .shuttingDown)
    }
}

struct ShutdownRouteTests {
    @Test
    func testShutdownReleasesTheNetworkOnceAndClosesTheAgent() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.provideNetwork(try .fake())
        let service = fake.makeService()
        let client = RouteClient(service: service)
        _ = try await client.bootstrap()

        _ = try await client.shutdown()

        #expect(fake.releasedNetworks == 1)
        #expect(await fake.agent.calls == [.close])
        #expect(await service.currentState == .shuttingDown)
        let second = await #expect(throws: ContainerizationError.self) { try await client.shutdown() }
        #expect(second?.code == .invalidState)
        #expect(fake.releasedNetworks == 1)
    }

    @Test
    func testShutdownBeforeBootstrapSucceeds() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let service = fake.makeService()
        let client = RouteClient(service: service)

        _ = try await client.shutdown()

        #expect(fake.releasedNetworks == 0)
        #expect(await service.currentState == .shuttingDown)
    }

    @Test
    func testShutdownIsRefusedWhileTheContainerRuns() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.provideNetwork(try .fake())
        let service = fake.makeService()
        let client = RouteClient(service: service)
        try await client.bootstrapAndStart()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.shutdown() }

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "cannot shutdown: container is not stopped")
        #expect(fake.releasedNetworks == 0)
        #expect(await service.currentState == .running)
    }
}

struct UnsupportedRouteTests {
    @Test(
        arguments: [
            RuntimeRoutes.dial.rawValue, RuntimeRoutes.statistics.rawValue, RuntimeRoutes.copyIn.rawValue,
            RuntimeRoutes.copyOut.rawValue, RuntimeRoutes.snapshotDisk.rawValue, RuntimeRoutes.clean.rawValue,
        ])
    func testTheRouteIsUnsupported(route: String) async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.unsupported(route) }

        #expect(refusal?.code == .unsupported)
        #expect(refusal?.message == "container-runtime-macos does not support this operation yet")
    }
}
