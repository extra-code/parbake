// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Records how a guest run ended, once, and wakes everyone waiting for it.
///
/// `@unchecked Sendable`: `lock` guards every mutable property.
final class ExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var exit: GuestExit?
    private var waiters: [CheckedContinuation<GuestExit, Never>] = []

    /// The exit, or nil while the guest runs.
    var current: GuestExit? {
        lock.withLock { exit }
    }

    /// Records the exit and resumes the waiters; a second call is ignored.
    func finish(exitCode: Int32) {
        let (exit, pending): (GuestExit?, [CheckedContinuation<GuestExit, Never>]) = lock.withLock {
            guard self.exit == nil else {
                return (nil, [])
            }
            let exit = GuestExit(exitCode: exitCode)
            self.exit = exit
            let pending = self.waiters
            self.waiters = []
            return (exit, pending)
        }
        guard let exit else {
            return
        }
        for cc in pending {
            cc.resume(returning: exit)
        }
    }

    /// Waits until `finish` was called.
    func wait() async -> GuestExit {
        await withCheckedContinuation { cc in
            let exit = lock.withLock {
                if self.exit == nil {
                    self.waiters.append(cc)
                }
                return self.exit
            }
            if let exit {
                cc.resume(returning: exit)
            }
        }
    }

    /// Waits until `finish` was called or `timeout` passes, and returns nil on timeout.
    func wait(timeout: Duration) async -> GuestExit? {
        let resumed = NSLock()
        nonisolated(unsafe) var done = false
        return await withCheckedContinuation { (cc: CheckedContinuation<GuestExit?, Never>) in
            let resume: @Sendable (GuestExit?) -> Void = { exit in
                let first = resumed.withLock {
                    defer { done = true }
                    return !done
                }
                if first {
                    cc.resume(returning: exit)
                }
            }
            Task { resume(await self.wait()) }
            Task {
                try? await Task.sleep(for: timeout)
                resume(self.current)
            }
        }
    }
}
