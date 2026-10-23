// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import ContainerLog
import ContainerPlugin
import ContainerRuntimeClient
import ContainerXPC
import Foundation
import Logging
import SystemPackage

extension RuntimeMacOSHelper {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start helper for a macOS container"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .shortAndLong, help: "Sandbox UUID")
        var uuid: String

        @Option(name: .shortAndLong, help: "Root directory for the sandbox")
        var root: String

        var logRoot = LogRoot.path

        /// Sends every message to the unified log and, when `logPath` is set, also to that file.
        static func bootstrapLogging(uuid: String, debug: Bool, logPath: FilePath?) -> Logger {
            let fileHandler = logPath.flatMap { try? FileLogHandler(label: "com.apple.container", category: "RuntimeMacOSHelper", path: $0) }
            LoggingSystem.bootstrap { _ in
                var handlers: [any LogHandler] = [OSLogHandler(category: "runtime")]
                if let fileHandler {
                    handlers.insert(fileHandler, at: 0)
                }
                return MultiplexLogHandler(handlers)
            }
            var log = Logger(label: "com.apple.container")
            log.logLevel = debug ? .debug : .info
            log[metadataKey: "uuid"] = "\(uuid)"
            if let logPath, fileHandler == nil {
                log.error("unable to open the log file, logging to the unified log only", metadata: ["logPath": "\(logPath)"])
            }
            return log
        }

        func run() async throws {
            let commandName = RuntimeMacOSHelper._commandName
            let logPath = logRoot.map { $0.appending("\(commandName)-\(uuid).log") }
            let log = Self.bootstrapLogging(uuid: uuid, debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(commandName)"])
            }

            do {
                signal(SIGPIPE, SIG_IGN)

                log.info("configuring XPC server")
                nonisolated(unsafe) let anonymousConnection = xpc_connection_create(nil, nil)

                let service = RuntimeService(
                    root: URL(fileURLWithPath: root),
                    connection: anonymousConnection,
                    log: log
                )

                let endpointServer = XPCServer(
                    identifier: RuntimeClient.machServiceLabel(runtime: commandName, id: uuid),
                    routes: [
                        RuntimeRoutes.createEndpoint.rawValue: XPCServer.route(service.createEndpoint)
                    ],
                    log: log
                )

                let mainServer = XPCServer(
                    connection: anonymousConnection,
                    routes: [
                        RuntimeRoutes.bootstrap.rawValue: XPCServer.route(service.bootstrap),
                        RuntimeRoutes.createProcess.rawValue: XPCServer.route(service.createProcess),
                        RuntimeRoutes.state.rawValue: XPCServer.route(service.state),
                        RuntimeRoutes.stop.rawValue: XPCServer.route(service.stop),
                        RuntimeRoutes.kill.rawValue: XPCServer.route(service.kill),
                        RuntimeRoutes.resize.rawValue: XPCServer.route(service.resize),
                        RuntimeRoutes.wait.rawValue: XPCServer.route(service.wait),
                        RuntimeRoutes.start.rawValue: XPCServer.route(service.startProcess),
                        RuntimeRoutes.dial.rawValue: XPCServer.route(service.unsupported),
                        RuntimeRoutes.shutdown.rawValue: XPCServer.route(service.shutdown),
                        RuntimeRoutes.statistics.rawValue: XPCServer.route(service.unsupported),
                        RuntimeRoutes.copyIn.rawValue: XPCServer.route(service.unsupported),
                        RuntimeRoutes.copyOut.rawValue: XPCServer.route(service.unsupported),
                        RuntimeRoutes.snapshotDisk.rawValue: XPCServer.route(service.unsupported),
                        RuntimeRoutes.clean.rawValue: XPCServer.route(service.unsupported),
                    ],
                    log: log
                )

                log.info("starting XPC server")
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await endpointServer.listen()
                    }
                    group.addTask {
                        try await mainServer.listen()
                    }
                    defer { group.cancelAll() }

                    _ = try await group.next()
                }
            } catch {
                log.error(
                    "helper failed",
                    metadata: [
                        "name": "\(commandName)",
                        "error": "\(error)",
                    ])
                RuntimeMacOSHelper.Start.exit(withError: error)
            }
        }
    }
}
