// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationExtras
import Foundation

@testable import container_runtime_macos

extension AllocatedNetwork {
    /// A network allocation on a fixed address; the handle is unused by the fakes.
    static func fake(address: String = "192.168.64.2/24") throws -> AllocatedNetwork {
        let attachment = try Attachment(
            network: "default", hostname: "fake", ipv4Address: CIDRv4(address), ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Address: nil, macAddress: nil)
        return AllocatedNetwork(attachment: attachment, handle: 0)
    }
}

/// Calls the routes of one service the way the runtime's client does.
struct RouteClient: Sendable {
    let service: RuntimeService
    /// The id of the container, which names the init process.
    let containerID = FakeRuntimeEnvironment.containerID

    func createEndpoint() async throws -> XPCMessage {
        try await callRoute(RuntimeRoutes.createEndpoint.rawValue, handler: service.createEndpoint)
    }

    func bootstrap() async throws -> XPCMessage {
        try await callRoute(RuntimeRoutes.bootstrap.rawValue, handler: service.bootstrap)
    }

    func start(_ id: String? = nil) async throws -> XPCMessage {
        try await callRoute(RuntimeRoutes.start.rawValue, configure: { $0.set(key: RuntimeKeys.id.rawValue, value: id ?? containerID) }, handler: service.startProcess)
    }

    func createProcess(_ id: String, configuration: ProcessConfiguration) async throws -> XPCMessage {
        try await callRoute(
            RuntimeRoutes.createProcess.rawValue,
            configure: {
                $0.set(key: RuntimeKeys.id.rawValue, value: id)
                $0.set(key: RuntimeKeys.processConfig.rawValue, value: (try? JSONEncoder().encode(configuration)) ?? Data())
            },
            handler: service.createProcess)
    }

    func state() async throws -> SandboxSnapshot {
        let reply = try await callRoute(RuntimeRoutes.state.rawValue, handler: service.state)
        let data = reply.dataNoCopy(key: RuntimeKeys.snapshot.rawValue) ?? Data()
        return try JSONDecoder().decode(SandboxSnapshot.self, from: data)
    }

    func stop(timeoutInSeconds: Int32 = 5) async throws -> XPCMessage {
        let options = ContainerStopOptions(timeoutInSeconds: timeoutInSeconds, signal: nil)
        return try await callRoute(
            RuntimeRoutes.stop.rawValue,
            configure: { $0.set(key: RuntimeKeys.stopOptions.rawValue, value: (try? JSONEncoder().encode(options)) ?? Data()) },
            handler: service.stop)
    }

    func kill(_ id: String? = nil, signal: String) async throws -> XPCMessage {
        try await callRoute(
            RuntimeRoutes.kill.rawValue,
            configure: {
                $0.set(key: RuntimeKeys.id.rawValue, value: id ?? containerID)
                $0.set(key: RuntimeKeys.signal.rawValue, value: signal)
            },
            handler: service.kill)
    }

    func resize(_ id: String, columns: UInt64, rows: UInt64) async throws -> XPCMessage {
        try await callRoute(
            RuntimeRoutes.resize.rawValue,
            configure: {
                $0.set(key: RuntimeKeys.id.rawValue, value: id)
                $0.set(key: RuntimeKeys.width.rawValue, value: columns)
                $0.set(key: RuntimeKeys.height.rawValue, value: rows)
            },
            handler: service.resize)
    }

    func wait(_ id: String? = nil) async throws -> XPCMessage {
        try await callRoute(
            RuntimeRoutes.wait.rawValue, configure: { $0.set(key: RuntimeKeys.id.rawValue, value: id ?? containerID) }, handler: service.wait)
    }

    func shutdown() async throws -> XPCMessage {
        try await callRoute(RuntimeRoutes.shutdown.rawValue, handler: service.shutdown)
    }

    func unsupported(_ route: String) async throws -> XPCMessage {
        try await callRoute(route, handler: service.unsupported)
    }

    /// Prepares the guest and boots it, as `container run` does.
    func bootstrapAndStart() async throws {
        _ = try await bootstrap()
        _ = try await start()
    }
}
