// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Testing
import vmnet

@testable import RuntimeMacOS
@testable import container_runtime_macos

struct CreateEndpointRouteTests {
    @Test
    func testCreateEndpointRepliesWithAnEndpoint() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())

        let reply = try await client.createEndpoint()

        #expect(reply.endpoint(key: RuntimeKeys.runtimeServiceEndpoint.rawValue) != nil)
    }
}

struct BootstrapRouteTests {
    @Test
    func testBootstrapPreparesTheGuestFromTheBundleLabel() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let service = fake.makeService()

        _ = try await callRoute(RuntimeRoutes.bootstrap.rawValue, handler: service.bootstrap)

        #expect(
            fake.calls == [
                .loadConfiguration,
                .validateBundlePath("/fake/bundle"),
                .openInstance(
                    bundle: URL(fileURLWithPath: "/fake/bundle"), instance: URL(fileURLWithPath: "/fake/root/vm"), resetOverlay: false),
                .allocateNetwork,
                .makeGuest(cpus: 4, memory: 1024 << 20, hasNetwork: false),
            ])
        #expect(await service.currentState == .prepared)
    }

    @Test
    func testASecondBootstrapIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())
        _ = try await client.bootstrap()

        let second = await #expect(throws: ContainerizationError.self) { try await client.bootstrap() }

        #expect(second?.code == .invalidState)
        #expect(second?.message == "container expected to be in created state, got: prepared")
    }

    @Test
    func testBootstrapHandsTheAllocatedNetworkToTheGuest() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.provideNetwork(try .fake())
        let client = RouteClient(service: fake.makeService())

        _ = try await client.bootstrap()

        #expect(fake.calls.last == .makeGuest(cpus: 4, memory: 1024 << 20, hasNetwork: true))
        #expect(try await client.state().networks.count == 1)
    }

    @Test
    func testBootstrapRefusesMounts() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.configure { $0.mounts = [Filesystem()] }
        let service = fake.makeService()
        let client = RouteClient(service: service)

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.bootstrap() }

        #expect(refusal?.code == .unsupported)
        #expect(refusal?.message == "-v/--mount is not supported for macOS guests; remove the option")
        #expect(await service.currentState == .created)
    }

    @Test
    func testBootstrapRefusesPublishedPorts() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let port = try PublishPort(hostAddress: IPAddress("127.0.0.1"), hostPort: 8080, containerPort: 80, proto: .tcp, count: 1)
        fake.configure { $0.publishedPorts = [port] }
        let client = RouteClient(service: fake.makeService())

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.bootstrap() }

        #expect(refusal?.code == .unsupported)
        #expect(refusal?.message == "-p/--publish is not supported for macOS guests; remove the option")
    }

    @Test
    func testBootstrapRefusesMountsAndPortsTogether() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        let port = try PublishPort(hostAddress: IPAddress("127.0.0.1"), hostPort: 8080, containerPort: 80, proto: .tcp, count: 1)
        fake.configure {
            $0.mounts = [Filesystem()]
            $0.publishedPorts = [port]
        }
        let client = RouteClient(service: fake.makeService())

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.bootstrap() }

        #expect(refusal?.code == .unsupported)
        #expect(refusal?.message == "-v/--mount and -p/--publish are not supported for macOS guests; remove the options")
    }

    @Test
    func testBootstrapWithoutTheBundleLabelIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.configure { $0.labels = [:] }
        let client = RouteClient(service: fake.makeService())

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.bootstrap() }

        #expect(refusal?.code == .invalidArgument)
        #expect(refusal?.message == "set --label runtime-macos.bundle=<path> to the macOS VM bundle to boot")
    }

    @Test
    func testABadBundlePathMapsToInvalidArgumentWithTheReasonText() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.failBundlePath(with: RuntimeFailure.bundlePath(.writableByOthers(path: "/fake/bundle")))
        let service = fake.makeService()
        let client = RouteClient(service: service)

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.bootstrap() }

        #expect(refusal?.code == .invalidArgument)
        #expect(refusal?.message == "/fake/bundle is writable by other users; run chmod go-w on it")
        #expect(await service.currentState == .created)
    }

    @Test
    func testAnUnknownOverlayPolicyIsRefused() async throws {
        let fake = try FakeRuntimeEnvironment(labels: [RuntimeService.incompatibleOverlayLabel: "keep"])
        defer { fake.cleanUp() }
        let client = RouteClient(service: fake.makeService())

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.bootstrap() }

        #expect(refusal?.code == .invalidArgument)
        #expect(refusal?.message == "runtime-macos.on-incompatible-overlay must be fail or discard, got keep")
    }

    @Test
    func testAnIncompatibleOverlayIsRefusedAndTheNetworkReleased() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.provideNetwork(try .fake())
        fake.failMakeGuest(with: [RuntimeFailure.incompatibleOverlay(bundle: "/vm", base: "/base", reason: "the base changed")])
        let service = fake.makeService()
        let client = RouteClient(service: service)

        let refusal = await #expect(throws: ContainerizationError.self) { try await client.bootstrap() }

        #expect(refusal?.code == .invalidState)
        #expect(
            refusal?.message
                == "the overlay in /vm does not stack on /base: the base changed; set --label runtime-macos.on-incompatible-overlay=discard to start the instance over"
        )
        #expect(fake.releasedNetworks == 1)
        #expect(await service.currentState == .created)
    }

    @Test
    func testAFailedNetworkAllocationReplyIsAnInternalError() async throws {
        let fake = try FakeRuntimeEnvironment()
        defer { fake.cleanUp() }
        fake.failAllocateNetwork(with: GuestDHCPServer.startFailure(.VMNET_FAILURE))
        let service = fake.makeService()
        let client = RouteClient(service: service)

        let failure = await #expect(throws: ContainerizationError.self) { try await client.bootstrap() }

        #expect(failure?.code == .internalError)
        #expect(
            failure?.message
                == "failed to start the DHCP interface on the vmnet network, status \(vmnet_return_t.VMNET_FAILURE.rawValue)")
        #expect(await service.currentState == .created)
    }

    @Test
    func testAnIncompatibleOverlayIsResetWhenTheDiscardLabelIsSet() async throws {
        let fake = try FakeRuntimeEnvironment(labels: [RuntimeService.incompatibleOverlayLabel: "discard"])
        defer { fake.cleanUp() }
        fake.failMakeGuest(with: [RuntimeFailure.incompatibleOverlay(bundle: "/vm", base: "/base", reason: "the base changed")])
        let service = fake.makeService()
        let client = RouteClient(service: service)

        _ = try await client.bootstrap()

        let opens = fake.calls.compactMap { call -> Bool? in
            if case .openInstance(_, _, let reset) = call { return reset }
            return nil
        }
        #expect(opens == [false, true])
        #expect(fake.calls.filter { if case .makeGuest = $0 { true } else { false } }.count == 2)
        #expect(await service.currentState == .prepared)
    }
}
