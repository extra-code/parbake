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

struct CreateProcessRouteTests {
    @Test
    func testTheOCIUserAndArgumentsReachTheAgent() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()
        let configuration = ProcessConfiguration(
            executable: "/bin/echo", arguments: ["hi", "there"], environment: ["A=1"], workingDirectory: "/work", terminal: true,
            user: .raw(userString: "builder"), supplementalGroups: [20])

        _ = try await client.createProcess("proc", configuration: configuration)

        let created = await fake.agent.createdProcesses
        #expect(created.map(\.id) == ["proc"])
        let process = try #require(created.first?.process)
        #expect(process.args == ["/bin/echo", "hi", "there"])
        #expect(process.env == ["A=1"])
        #expect(process.cwd == "/work")
        #expect(process.terminal)
        #expect(process.user.username == "builder")
        #expect(process.user.additionalGids == [20])
    }

    @Test
    func testRootBecomesTheProvisionedAccount() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        try fake.provisionGuest(username: "builder")
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()
        let configuration = ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [], user: .id(uid: 0, gid: 0))

        _ = try await client.createProcess("proc", configuration: configuration)

        let process = try #require(await fake.agent.createdProcesses.first?.process)
        #expect(process.user.username == "builder")
        #expect(process.user.uid == 0)
    }

    @Test
    func testANumericUserKeepsItsIDs() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()
        let configuration = ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [], user: .id(uid: 501, gid: 20))

        _ = try await client.createProcess("proc", configuration: configuration)

        let process = try #require(await fake.agent.createdProcesses.first?.process)
        #expect(process.user.uid == 501)
        #expect(process.user.gid == 20)
        #expect(process.user.username.isEmpty)
    }

    @Test
    func testCreatingAProcessOfAContainerThatIsNotRunningIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        _ = try await client.bootstrap()
        let configuration = ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [])

        let refusal = await #expect(throws: ContainerizationError.self) {
            try await client.createProcess("proc", configuration: configuration)
        }

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "container is not running")
        #expect(await fake.agent.createdProcesses.isEmpty)
    }
}

struct ResizeRouteTests {
    @Test
    func testTheTerminalSizeIsForwardedToTheAgent() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.resize("proc", columns: 80, rows: 24)

        #expect(await fake.agent.calls == [.resize(id: "proc", columns: 80, rows: 24)])
    }

    @Test
    func testTheInitProcessHasNoTerminalToResize() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        _ = try await client.resize(client.containerID, columns: 80, rows: 24)

        #expect(await fake.agent.calls.isEmpty)
    }

    @Test
    func testResizingBeforeTheContainerRunsIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        _ = try await client.bootstrap()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.resize("proc", columns: 80, rows: 24) }

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "container is not running")
    }

    @Test
    func testResizingBeforeBootstrapIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.resize("proc", columns: 80, rows: 24) }

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "container is not bootstrapped")
    }
}

struct WaitRouteTests {
    private let exitedAt = Date(timeIntervalSince1970: 2_000_000)

    @Test
    func testTheInitProcessWaitReportsTheGuestExit() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()
        fake.machine.stop(with: GuestExit(exitCode: 3, exitedAt: exitedAt))

        let reply = try await client.wait()

        #expect(reply.int64(key: RuntimeKeys.exitCode.rawValue) == 3)
        #expect(reply.date(key: RuntimeKeys.exitedAt.rawValue) == exitedAt)
    }

    @Test
    func testAnotherProcessWaitReportsTheAgentsExit() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()
        await fake.agent.configure(exits: ["proc": GuestExit(exitCode: 7, exitedAt: exitedAt)])

        let reply = try await client.wait("proc")

        #expect(reply.int64(key: RuntimeKeys.exitCode.rawValue) == 7)
        #expect(reply.date(key: RuntimeKeys.exitedAt.rawValue) == exitedAt)
        #expect(await fake.agent.calls == [.wait(id: "proc")])
    }

    @Test
    func testWaitingForAProcessOfAContainerThatIsNotRunningIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        _ = try await client.bootstrap()

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.wait("proc") }

        #expect(refusal?.code == .invalidState)
        #expect(refusal?.message == "container is not running")
    }

    @Test
    func testALostProcessOfARunningGuestIsInterrupted() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()
        await fake.agent.configure(failure: RuntimeFailure.processLost(id: "proc", cause: "the stream ended"))

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.wait("proc") }

        #expect(refusal?.code == .interrupted)
        #expect(
            refusal?.message == "lost the guest agent's stream for process proc while the guest kept running; its exit code is unknown")
        #expect(fake.machine.calls.contains(.waitWithTimeout(RuntimeLifecycle.guestLossTimeout)))
    }

    @Test
    func testALostProcessOfAStoppedGuestNamesTheGuestExitCode() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()
        await fake.agent.configure(failure: RuntimeFailure.processLost(id: "proc", cause: "the stream ended"))
        fake.machine.stopOn(.waitWithTimeout(RuntimeLifecycle.guestLossTimeout), exit: GuestExit(exitCode: 9))

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.wait("proc") }

        #expect(refusal?.code == .interrupted)
        #expect(refusal?.message == "the macOS guest stopped with exit code 9 while process proc ran; the process has no exit code")
    }
}

struct AgentFailureRouteTests {
    @Test
    func testCreateProcessReportsAnAgentFailureAsAContainerizationError() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        await fake.agent.configure(failure: RuntimeFailure.exists("process proc already exists"))
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()
        let configuration = ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [])

        let failure = await #expect(throws: ContainerizationError.self) {
            try await client.createProcess("proc", configuration: configuration)
        }

        #expect(failure?.code == .exists)
        #expect(failure?.message == "process proc already exists")
    }

    @Test
    func testStartingAProcessReportsAnAgentFailureAsAContainerizationError() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        await fake.agent.configure(failure: RuntimeFailure.invalidState("process proc is not started"))
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let failure = await #expect(throws: ContainerizationError.self) { try await client.start("proc") }

        #expect(failure?.code == .invalidState)
        #expect(failure?.message == "process proc is not started")
    }

    @Test
    func testSignallingAProcessReportsAnAgentFailureAsAContainerizationError() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        await fake.agent.configure(failure: RuntimeFailure.notFound("process proc does not exist"))
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let failure = await #expect(throws: ContainerizationError.self) { try await client.kill("proc", signal: "TERM") }

        #expect(failure?.code == .notFound)
        #expect(failure?.message == "process proc does not exist")
    }

    @Test
    func testResizingAProcessReportsAnAgentFailureAsAContainerizationError() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        await fake.agent.configure(failure: RuntimeFailure.notFound("process proc does not exist"))
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let failure = await #expect(throws: ContainerizationError.self) { try await client.resize("proc", columns: 80, rows: 24) }

        #expect(failure?.code == .notFound)
    }

    @Test
    func testWaitingForAProcessReportsAnAgentFailureAsAContainerizationError() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        await fake.agent.configure(failure: RuntimeFailure.notFound("process proc does not exist"))
        let client = RouteClient(service: fake.makeService())
        try await client.bootstrapAndStart()

        let failure = await #expect(throws: ContainerizationError.self) { try await client.wait("proc") }

        #expect(failure?.code == .notFound)
        #expect(failure?.message == "process proc does not exist")
    }
}
