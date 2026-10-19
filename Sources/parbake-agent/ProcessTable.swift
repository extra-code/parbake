// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

/// The processes the agent created, by ID.
actor ProcessTable {
    private var processes: [String: GuestProcess] = [:]

    func add(_ process: GuestProcess) throws {
        guard processes[process.id] == nil else {
            throw AgentError.alreadyExists("process \(process.id) already exists")
        }
        processes[process.id] = process
    }

    func process(_ id: String) throws -> GuestProcess {
        guard let process = processes[id] else {
            throw AgentError.notFound("process \(id) does not exist")
        }
        return process
    }

    /// Forgets an exited process, or one that never started.
    func remove(_ id: String) throws {
        let process = try process(id)
        guard !process.isRunning else {
            throw AgentError.failedPrecondition("process \(id) is still running")
        }
        processes[id] = nil
    }
}
