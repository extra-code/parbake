// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Containerization
import ContainerizationOCI
import Foundation
import GRPCCore
import SwiftProtobuf

typealias SandboxContext = Com_Apple_Containerization_Sandbox_V3_SandboxContext
typealias CloseProcessStdinRequest = Com_Apple_Containerization_Sandbox_V3_CloseProcessStdinRequest
typealias CloseProcessStdinResponse = Com_Apple_Containerization_Sandbox_V3_CloseProcessStdinResponse
typealias ConfigureDnsRequest = Com_Apple_Containerization_Sandbox_V3_ConfigureDnsRequest
typealias ConfigureDnsResponse = Com_Apple_Containerization_Sandbox_V3_ConfigureDnsResponse
typealias ConfigureHostsRequest = Com_Apple_Containerization_Sandbox_V3_ConfigureHostsRequest
typealias ConfigureHostsResponse = Com_Apple_Containerization_Sandbox_V3_ConfigureHostsResponse
typealias ContainerStatisticsRequest = Com_Apple_Containerization_Sandbox_V3_ContainerStatisticsRequest
typealias ContainerStatisticsResponse = Com_Apple_Containerization_Sandbox_V3_ContainerStatisticsResponse
typealias CopyRequest = Com_Apple_Containerization_Sandbox_V3_CopyRequest
typealias CopyResponse = Com_Apple_Containerization_Sandbox_V3_CopyResponse
typealias CreateProcessRequest = Com_Apple_Containerization_Sandbox_V3_CreateProcessRequest
typealias CreateProcessResponse = Com_Apple_Containerization_Sandbox_V3_CreateProcessResponse
typealias DeleteProcessRequest = Com_Apple_Containerization_Sandbox_V3_DeleteProcessRequest
typealias DeleteProcessResponse = Com_Apple_Containerization_Sandbox_V3_DeleteProcessResponse
typealias FilesystemOperationRequest = Com_Apple_Containerization_Sandbox_V3_FilesystemOperationRequest
typealias FilesystemOperationResponse = Com_Apple_Containerization_Sandbox_V3_FilesystemOperationResponse
typealias GetenvRequest = Com_Apple_Containerization_Sandbox_V3_GetenvRequest
typealias GetenvResponse = Com_Apple_Containerization_Sandbox_V3_GetenvResponse
typealias IpAddrAddRequest = Com_Apple_Containerization_Sandbox_V3_IpAddrAddRequest
typealias IpAddrAddResponse = Com_Apple_Containerization_Sandbox_V3_IpAddrAddResponse
typealias IpLinkSetRequest = Com_Apple_Containerization_Sandbox_V3_IpLinkSetRequest
typealias IpLinkSetResponse = Com_Apple_Containerization_Sandbox_V3_IpLinkSetResponse
typealias IpRouteAddDefaultRequest = Com_Apple_Containerization_Sandbox_V3_IpRouteAddDefaultRequest
typealias IpRouteAddDefaultResponse = Com_Apple_Containerization_Sandbox_V3_IpRouteAddDefaultResponse
typealias IpRouteAddLinkRequest = Com_Apple_Containerization_Sandbox_V3_IpRouteAddLinkRequest
typealias IpRouteAddLinkResponse = Com_Apple_Containerization_Sandbox_V3_IpRouteAddLinkResponse
typealias KillProcessRequest = Com_Apple_Containerization_Sandbox_V3_KillProcessRequest
typealias KillProcessResponse = Com_Apple_Containerization_Sandbox_V3_KillProcessResponse
typealias KillRequest = Com_Apple_Containerization_Sandbox_V3_KillRequest
typealias KillResponse = Com_Apple_Containerization_Sandbox_V3_KillResponse
typealias MkdirRequest = Com_Apple_Containerization_Sandbox_V3_MkdirRequest
typealias MkdirResponse = Com_Apple_Containerization_Sandbox_V3_MkdirResponse
typealias MountRequest = Com_Apple_Containerization_Sandbox_V3_MountRequest
typealias MountResponse = Com_Apple_Containerization_Sandbox_V3_MountResponse
typealias ProxyVsockRequest = Com_Apple_Containerization_Sandbox_V3_ProxyVsockRequest
typealias ProxyVsockResponse = Com_Apple_Containerization_Sandbox_V3_ProxyVsockResponse
typealias ResizeProcessRequest = Com_Apple_Containerization_Sandbox_V3_ResizeProcessRequest
typealias ResizeProcessResponse = Com_Apple_Containerization_Sandbox_V3_ResizeProcessResponse
typealias SetTimeRequest = Com_Apple_Containerization_Sandbox_V3_SetTimeRequest
typealias SetTimeResponse = Com_Apple_Containerization_Sandbox_V3_SetTimeResponse
typealias SetenvRequest = Com_Apple_Containerization_Sandbox_V3_SetenvRequest
typealias SetenvResponse = Com_Apple_Containerization_Sandbox_V3_SetenvResponse
typealias SetupEmulatorRequest = Com_Apple_Containerization_Sandbox_V3_SetupEmulatorRequest
typealias SetupEmulatorResponse = Com_Apple_Containerization_Sandbox_V3_SetupEmulatorResponse
typealias StartProcessRequest = Com_Apple_Containerization_Sandbox_V3_StartProcessRequest
typealias StartProcessResponse = Com_Apple_Containerization_Sandbox_V3_StartProcessResponse
typealias StatRequest = Com_Apple_Containerization_Sandbox_V3_StatRequest
typealias StatResponse = Com_Apple_Containerization_Sandbox_V3_StatResponse
typealias StopVsockProxyRequest = Com_Apple_Containerization_Sandbox_V3_StopVsockProxyRequest
typealias StopVsockProxyResponse = Com_Apple_Containerization_Sandbox_V3_StopVsockProxyResponse
typealias SyncRequest = Com_Apple_Containerization_Sandbox_V3_SyncRequest
typealias SyncResponse = Com_Apple_Containerization_Sandbox_V3_SyncResponse
typealias SysctlRequest = Com_Apple_Containerization_Sandbox_V3_SysctlRequest
typealias SysctlResponse = Com_Apple_Containerization_Sandbox_V3_SysctlResponse
typealias UmountRequest = Com_Apple_Containerization_Sandbox_V3_UmountRequest
typealias UmountResponse = Com_Apple_Containerization_Sandbox_V3_UmountResponse
typealias WaitProcessRequest = Com_Apple_Containerization_Sandbox_V3_WaitProcessRequest
typealias WaitProcessResponse = Com_Apple_Containerization_Sandbox_V3_WaitProcessResponse
typealias WriteFileRequest = Com_Apple_Containerization_Sandbox_V3_WriteFileRequest
typealias WriteFileResponse = Com_Apple_Containerization_Sandbox_V3_WriteFileResponse

/// The macOS subset of containerization's SandboxContext service.
///
/// `Getenv` reads the agent's own environment, which carries the agent version. Processes run with
/// separate standard streams over vsock. Every other call answers `UNIMPLEMENTED`.
struct SandboxService: SandboxContext.SimpleServiceProtocol {
    let processes = ProcessTable()

    func createProcess(request: CreateProcessRequest, context: ServerContext) async throws -> CreateProcessResponse {
        try await mapErrors {
            let process: ContainerizationOCI.Process
            do {
                guard let decoded = try JSONDecoder().decode(ContainerizationOCI.Spec.self, from: request.configuration).process else {
                    throw AgentError.invalidArgument("the configuration carries no process")
                }
                process = decoded
            } catch let error as AgentError {
                throw error
            } catch {
                throw AgentError.invalidArgument("the configuration is no OCI spec: \(error)")
            }
            let guestProcess = try GuestProcess(
                id: request.id,
                process: process,
                stdin: request.hasStdin ? request.stdin : nil,
                stdout: request.hasStdout ? request.stdout : nil,
                stderr: request.hasStderr ? request.stderr : nil
            )
            try await processes.add(guestProcess)
            return CreateProcessResponse()
        }
    }

    func startProcess(request: StartProcessRequest, context: ServerContext) async throws -> StartProcessResponse {
        try await mapErrors {
            let process = try await processes.process(request.id)
            var response = StartProcessResponse()
            response.pid = try process.start()
            return response
        }
    }

    func waitProcess(request: WaitProcessRequest, context: ServerContext) async throws -> WaitProcessResponse {
        try await mapErrors {
            let exit = try await processes.process(request.id).wait()
            var response = WaitProcessResponse()
            response.exitCode = exit.code
            response.exitedAt = Google_Protobuf_Timestamp(date: exit.date)
            return response
        }
    }

    func killProcess(request: KillProcessRequest, context: ServerContext) async throws -> KillProcessResponse {
        try await mapErrors {
            try await processes.process(request.id).signal(request.signal)
            return KillProcessResponse()
        }
    }

    func deleteProcess(request: DeleteProcessRequest, context: ServerContext) async throws -> DeleteProcessResponse {
        try await mapErrors {
            try await processes.remove(request.id)
            return DeleteProcessResponse()
        }
    }

    func closeProcessStdin(request: CloseProcessStdinRequest, context: ServerContext) async throws -> CloseProcessStdinResponse {
        try await mapErrors {
            try await processes.process(request.id).closeStdin()
            return CloseProcessStdinResponse()
        }
    }

    func kill(request: KillRequest, context: ServerContext) async throws -> KillResponse {
        var response = KillResponse()
        response.result = Darwin.kill(request.pid, request.signal) == 0 ? 0 : -errno
        return response
    }

    func setTime(request: SetTimeRequest, context: ServerContext) async throws -> SetTimeResponse {
        try await mapErrors {
            var time = timeval(tv_sec: Int(request.sec), tv_usec: request.usec)
            guard settimeofday(&time, nil) == 0 else {
                throw AgentError.posix("settimeofday", errno)
            }
            return SetTimeResponse()
        }
    }

    private func mapErrors<Response>(_ body: () async throws -> Response) async throws -> Response {
        do {
            return try await body()
        } catch let error as AgentError {
            throw error.rpcError
        }
    }

    func getenv(request: GetenvRequest, context: ServerContext) async throws -> GetenvResponse {
        var response = GetenvResponse()
        if let value = ProcessInfo.processInfo.environment[request.key] {
            response.value = value
        }
        return response
    }

    func sync(request: SyncRequest, context: ServerContext) async throws -> SyncResponse {
        Darwin.sync()
        return SyncResponse()
    }

    func mount(request: MountRequest, context: ServerContext) async throws -> MountResponse {
        throw Self.unimplemented("mount")
    }

    func umount(request: UmountRequest, context: ServerContext) async throws -> UmountResponse {
        throw Self.unimplemented("umount")
    }

    func setenv(request: SetenvRequest, context: ServerContext) async throws -> SetenvResponse {
        throw Self.unimplemented("setenv")
    }

    func mkdir(request: MkdirRequest, context: ServerContext) async throws -> MkdirResponse {
        throw Self.unimplemented("mkdir")
    }

    func sysctl(request: SysctlRequest, context: ServerContext) async throws -> SysctlResponse {
        throw Self.unimplemented("sysctl")
    }

    func setupEmulator(request: SetupEmulatorRequest, context: ServerContext) async throws -> SetupEmulatorResponse {
        throw Self.unimplemented("setupEmulator")
    }

    func writeFile(request: WriteFileRequest, context: ServerContext) async throws -> WriteFileResponse {
        throw Self.unimplemented("writeFile")
    }

    func copy(request: CopyRequest, response: RPCWriter<CopyResponse>, context: ServerContext) async throws {
        throw Self.unimplemented("copy")
    }

    func stat(request: StatRequest, context: ServerContext) async throws -> StatResponse {
        throw Self.unimplemented("stat")
    }

    func filesystemOperation(request: FilesystemOperationRequest, context: ServerContext) async throws -> FilesystemOperationResponse {
        throw Self.unimplemented("filesystemOperation")
    }

    func resizeProcess(request: ResizeProcessRequest, context: ServerContext) async throws -> ResizeProcessResponse {
        throw Self.unimplemented("resizeProcess")
    }

    func containerStatistics(request: ContainerStatisticsRequest, context: ServerContext) async throws -> ContainerStatisticsResponse {
        throw Self.unimplemented("containerStatistics")
    }

    func proxyVsock(request: ProxyVsockRequest, context: ServerContext) async throws -> ProxyVsockResponse {
        throw Self.unimplemented("proxyVsock")
    }

    func stopVsockProxy(request: StopVsockProxyRequest, context: ServerContext) async throws -> StopVsockProxyResponse {
        throw Self.unimplemented("stopVsockProxy")
    }

    func ipLinkSet(request: IpLinkSetRequest, context: ServerContext) async throws -> IpLinkSetResponse {
        throw Self.unimplemented("ipLinkSet")
    }

    func ipAddrAdd(request: IpAddrAddRequest, context: ServerContext) async throws -> IpAddrAddResponse {
        throw Self.unimplemented("ipAddrAdd")
    }

    func ipRouteAddLink(request: IpRouteAddLinkRequest, context: ServerContext) async throws -> IpRouteAddLinkResponse {
        throw Self.unimplemented("ipRouteAddLink")
    }

    func ipRouteAddDefault(request: IpRouteAddDefaultRequest, context: ServerContext) async throws -> IpRouteAddDefaultResponse {
        throw Self.unimplemented("ipRouteAddDefault")
    }

    func configureDns(request: ConfigureDnsRequest, context: ServerContext) async throws -> ConfigureDnsResponse {
        throw Self.unimplemented("configureDns")
    }

    func configureHosts(request: ConfigureHostsRequest, context: ServerContext) async throws -> ConfigureHostsResponse {
        throw Self.unimplemented("configureHosts")
    }

    static func unimplemented(_ method: String) -> RPCError {
        RPCError(code: .unimplemented, message: "parbake-agent does not implement \(method)")
    }
}
