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

    func setRuntimeSnapshot(_ snapshot: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        self.set(key: RuntimeKeys.snapshot.rawValue, value: data)
    }
}
