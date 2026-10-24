// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A point in a fake that holds callers until the test lets them through, without sleeping.
///
/// A fake calls `pass()` where it must be able to wait. A test that wants to hold the caller uses
/// `untilArrived` to know the caller has reached the gate, then `open()` or `fail(_:)`. A caller that
/// reaches an open gate passes at once; cancelling a held caller makes `pass()` throw `CancellationError`.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?
    private var held: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextID = 0
    private var arrived = 0

    /// How many callers have reached the gate so far.
    var arrivals: Int { lock.withLock { arrived } }

    /// Called by the fake: returns when the gate is open and throws when it failed or the caller is cancelled.
    func pass() async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (settled, ready) = lock.withLock { () -> (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) in
                    arrived += 1
                    let ready = watchers.filter { $0.count <= arrived }.map(\.continuation)
                    watchers.removeAll { $0.count <= arrived }
                    if let outcome { return (outcome, ready) }
                    if Task.isCancelled { return (.failure(CancellationError()), ready) }
                    held[id] = continuation
                    return (nil, ready)
                }
                if let settled { continuation.resume(with: settled) }
                for watcher in ready { watcher.resume() }
            }
        } onCancel: {
            let continuation = lock.withLock { held.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Returns once `count` callers have reached the gate.
    func untilArrived(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if arrived >= count { return true }
                watchers.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Lets every held and later caller through.
    func open() { finish(.success(())) }

    /// Makes every held and later caller throw `error`.
    func fail(_ error: any Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Void, any Error>) {
        let released = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            if outcome == nil { outcome = result }
            defer { held = [:] }
            return Array(held.values)
        }
        for continuation in released { continuation.resume(with: result) }
    }
}
