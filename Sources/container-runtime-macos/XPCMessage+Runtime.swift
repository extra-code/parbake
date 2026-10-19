// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import Foundation

extension XPCMessage {
    func runtimeStopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: RuntimeKeys.stopOptions.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "empty stop options")
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }

    func processConfiguration() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: RuntimeKeys.processConfig.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "empty process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }

    /// The caller's standard input, output and error; each is nil when the caller passed none.
    func stdio() -> [FileHandle?] {
        [RuntimeKeys.stdin, .stdout, .stderr].map { self.fileHandle(key: $0.rawValue) }
    }

    func setRuntimeSnapshot(_ snapshot: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        self.set(key: RuntimeKeys.snapshot.rawValue, value: data)
    }
}
