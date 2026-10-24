// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import GRPCCore
import Testing

@testable import parbake_agent

struct SandboxServiceTests {
    private func create(_ service: SandboxService, id: String, args: [String]) async throws {
        var request = CreateProcessRequest()
        request.id = id
        request.configuration = try specConfiguration(args)
        _ = try await withServerContext { try await service.createProcess(request: request, context: $0) }
    }

    private func start(_ service: SandboxService, id: String) async throws -> Int32 {
        var request = StartProcessRequest()
        request.id = id
        return try await withServerContext { try await service.startProcess(request: request, context: $0) }.pid
    }

    private func wait(_ service: SandboxService, id: String) async throws -> Int32 {
        var request = WaitProcessRequest()
        request.id = id
        return try await withServerContext { try await service.waitProcess(request: request, context: $0) }.exitCode
    }

    private func kill(_ service: SandboxService, id: String, signal: Int32 = SIGTERM) async throws {
        var request = KillProcessRequest()
        request.id = id
        request.signal = signal
        _ = try await withServerContext { try await service.killProcess(request: request, context: $0) }
    }

    private func delete(_ service: SandboxService, id: String) async throws {
        var request = DeleteProcessRequest()
        request.id = id
        _ = try await withServerContext { try await service.deleteProcess(request: request, context: $0) }
    }

    /// Runs `body` with a started `sleep 60` process `id`, and kills and reaps it afterwards even when `body` throws.
    private func withSleeper(_ service: SandboxService, id: String, _ body: () async throws -> Void) async throws {
        try await create(service, id: id, args: ["/bin/sleep", "60"])
        _ = try await start(service, id: id)
        do {
            try await body()
        } catch {
            try? await kill(service, id: id)
            _ = try? await wait(service, id: id)
            throw error
        }
        try? await kill(service, id: id)
        _ = try? await wait(service, id: id)
    }

    @Test
    func testCreateAddsTheProcess() async throws {
        let service = SandboxService()
        try await create(service, id: "a", args: ["/usr/bin/true"])
        _ = try await service.processes.process("a")
    }

    @Test
    func testCreateWithoutArgumentsIsInvalid() async throws {
        let service = SandboxService()
        let code = await rpcCode { try await create(service, id: "a", args: []) }
        #expect(code == .invalidArgument)
    }

    @Test
    func testCreateWithADuplicateIDAlreadyExists() async throws {
        let service = SandboxService()
        try await create(service, id: "a", args: ["/usr/bin/true"])
        let code = await rpcCode { try await create(service, id: "a", args: ["/usr/bin/true"]) }
        #expect(code == .alreadyExists)
    }

    @Test
    func testCreateWithoutAProcessIsInvalid() async throws {
        let service = SandboxService()
        var request = CreateProcessRequest()
        request.id = "a"
        request.configuration = Data("{}".utf8)
        let code = await rpcCode {
            _ = try await withServerContext { try await service.createProcess(request: request, context: $0) }
        }
        #expect(code == .invalidArgument)
    }

    @Test
    func testStartReturnsAPIDAndWaitReportsExitZero() async throws {
        let service = SandboxService()
        try await create(service, id: "a", args: ["/usr/bin/true"])
        let pid = try await start(service, id: "a")
        #expect(pid > 0)
        #expect(try await wait(service, id: "a") == 0)
    }

    @Test
    func testWaitReportsTheExitCode() async throws {
        let service = SandboxService()
        try await create(service, id: "a", args: ["/bin/sh", "-c", "exit 7"])
        _ = try await start(service, id: "a")
        #expect(try await wait(service, id: "a") == 7)
    }

    @Test
    func testKillEndsAProcessWith128PlusTheSignal() async throws {
        let service = SandboxService()
        try await withSleeper(service, id: "a") {
            try await kill(service, id: "a")
            #expect(try await wait(service, id: "a") == 128 + SIGTERM)
        }
    }

    @Test
    func testKillOfAProcessThatIsNotRunningFailsThePrecondition() async throws {
        let service = SandboxService()
        try await create(service, id: "a", args: ["/usr/bin/true"])
        let code = await rpcCode { try await kill(service, id: "a") }
        #expect(code == .failedPrecondition)
    }

    @Test
    func testDeleteOfARunningProcessFailsThePrecondition() async throws {
        let service = SandboxService()
        try await withSleeper(service, id: "a") {
            let code = await rpcCode { try await delete(service, id: "a") }
            #expect(code == .failedPrecondition)
        }
    }

    @Test
    func testDeleteOfAnExitedProcessRemovesIt() async throws {
        let service = SandboxService()
        try await create(service, id: "a", args: ["/usr/bin/true"])
        _ = try await start(service, id: "a")
        _ = try await wait(service, id: "a")
        try await delete(service, id: "a")
        let code = await rpcCode { try await delete(service, id: "a") }
        #expect(code == .notFound)
    }

    @Test
    func testDeleteOfAProcessThatNeverStartedRemovesIt() async throws {
        let service = SandboxService()
        try await create(service, id: "a", args: ["/usr/bin/true"])
        try await delete(service, id: "a")
        let code = await rpcCode { _ = try await wait(service, id: "a") }
        #expect(code == .notFound)
    }

    @Test
    func testAnUnknownIDIsNotFoundOnEveryOperation() async throws {
        let service = SandboxService()
        #expect(await rpcCode { _ = try await start(service, id: "x") } == .notFound)
        #expect(await rpcCode { _ = try await wait(service, id: "x") } == .notFound)
        #expect(await rpcCode { try await kill(service, id: "x") } == .notFound)
        #expect(await rpcCode { try await delete(service, id: "x") } == .notFound)
        var close = CloseProcessStdinRequest()
        close.id = "x"
        #expect(
            await rpcCode { _ = try await withServerContext { try await service.closeProcessStdin(request: close, context: $0) } }
                == .notFound)
        var resize = ResizeProcessRequest()
        resize.id = "x"
        #expect(
            await rpcCode { _ = try await withServerContext { try await service.resizeProcess(request: resize, context: $0) } }
                == .notFound)
    }

    @Test
    func testResizeWithoutATerminalIsANoOp() async throws {
        let service = SandboxService()
        try await create(service, id: "a", args: ["/usr/bin/true"])
        var resize = ResizeProcessRequest()
        resize.id = "a"
        resize.columns = 80
        resize.rows = 24
        _ = try await withServerContext { try await service.resizeProcess(request: resize, context: $0) }
    }

    @Test
    func testAMissingExecutableIsNotFound() async throws {
        let service = SandboxService()
        try await create(service, id: "a", args: ["parbake-no-such-command"])
        let code = await rpcCode { _ = try await start(service, id: "a") }
        #expect(code == .notFound)
    }
}

struct UnimplementedCallTests {
    @Test
    func testAnUnimplementedCallMapsToUnimplementedWithTheSameMessage() async throws {
        let service = SandboxService()
        do {
            _ = try await withServerContext { try await service.mount(request: MountRequest(), context: $0) }
            Issue.record("mount did not throw")
        } catch let error as RPCError {
            #expect(error.code == .unimplemented)
            #expect(error.message == "parbake-agent does not implement mount")
        }
    }

    @Test
    func testAnUnimplementedStreamingCallMapsTheSameWay() async throws {
        let service = SandboxService()
        let code = await rpcCode {
            _ = try await withServerContext { try await service.stat(request: StatRequest(), context: $0) }
        }
        #expect(code == .unimplemented)
    }
}
