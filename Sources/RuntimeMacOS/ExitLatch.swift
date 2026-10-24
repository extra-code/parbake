// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Records how a guest run ended, once, and wakes everyone waiting for it.
///
/// `@unchecked Sendable`: `lock` guards every mutable property.
final class ExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var exit: GuestExit?
    private var waiters: [UUID: CheckedContinuation<GuestExit?, Never>] = [:]

    /// The exit, or nil while the guest runs.
    var current: GuestExit? {
        lock.withLock { exit }
    }

    /// Records the exit and resumes the waiters; a second call is ignored.
    func finish(exitCode: Int32) {
        let (exit, pending): (GuestExit?, [CheckedContinuation<GuestExit?, Never>]) = lock.withLock {
            guard self.exit == nil else {
                return (nil, [])
            }
            let exit = GuestExit(exitCode: exitCode)
            self.exit = exit
            let pending = Array(self.waiters.values)
            self.waiters = [:]
            return (exit, pending)
        }
        guard let exit else {
            return
        }
        for cc in pending {
            cc.resume(returning: exit)
        }
    }

    /// Waits until `finish` was called. Cancelling the caller does not end the wait.
    func wait() async -> GuestExit {
        while true {
            if let exit = await suspend(cancellable: false) {
                return exit
            }
        }
    }

    /// Waits until `finish` was called or `timeout` passes, and returns nil on timeout or when the caller is cancelled.
    func wait(timeout: Duration) async -> GuestExit? {
        await withTaskGroup(of: GuestExit?.self) { group in
            group.addTask { await self.suspend(cancellable: true) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return self.current
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Suspends until `finish`; nil when `cancellable` and the task is cancelled first.
    private func suspend(cancellable: Bool) async -> GuestExit? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cc: CheckedContinuation<GuestExit?, Never>) in
                let (exit, cancelled): (GuestExit?, Bool) = lock.withLock {
                    if let exit = self.exit {
                        return (exit, false)
                    }
                    if cancellable && Task.isCancelled {
                        return (nil, true)
                    }
                    self.waiters[id] = cc
                    return (nil, false)
                }
                if let exit {
                    cc.resume(returning: exit)
                } else if cancelled {
                    cc.resume(returning: nil)
                }
            }
        } onCancel: {
            guard cancellable else {
                return
            }
            lock.withLock { waiters.removeValue(forKey: id) }?.resume(returning: nil)
        }
    }
}
