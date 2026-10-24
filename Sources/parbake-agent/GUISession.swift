// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum GUISession {
    /// Throws `AgentError.failedPrecondition` when account `name` has no GUI session; uid 0 is not probed.
    static func require(uid: uid_t, name: String, probe: (uid_t) async -> Bool = GUISession.launchctlPrint) async throws {
        guard uid != 0 else { return }
        guard await probe(uid) else {
            throw AgentError.failedPrecondition(
                "account \(name) has no GUI session; log it in (auto-login on a CI host) before running processes as it")
        }
    }

    /// Runs `/bin/launchctl print gui/<uid>` and returns whether it exits 0.
    static func launchctlPrint(uid: uid_t) async -> Bool {
        await AgentCommand.capture("/bin/launchctl", ["print", "gui/\(uid)"])?.status == 0
    }
}
