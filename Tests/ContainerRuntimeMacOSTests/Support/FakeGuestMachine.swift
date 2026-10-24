// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import RuntimeMacOS

/// A guest machine that records the calls it gets and never waits in real time.
///
/// `wait(timeout:)` answers at once with the exit the machine has, or `nil`; a test makes the machine
/// stop with `stop(with:)` or arranges for a call to stop it with `stopOn`.
final class FakeGuestMachine: GuestMachine, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case start
        case requestStop
        case forceStop
        case wait
        case waitWithTimeout(Duration)
    }

    struct Refused: Error {}

    let macAddress: String
    private let lock = NSLock()
    private var exit: GuestExit?
    private var recorded: [Call] = []
    private var stopTrigger: (call: Call, exit: GuestExit)?
    private var failing: Set<String> = []
    private var waiters: [CheckedContinuation<GuestExit, Never>] = []
    private var startGate: Gate?
    private var forceStopGate: Gate?
    private var forceStopFailures = 0
    private var startError: (any Error)?

    init(macAddress: String = "aa:bb:cc:dd:ee:ff", exit: GuestExit? = nil) {
        self.macAddress = macAddress
        self.exit = exit
    }

    /// The calls received so far, in order.
    var calls: [Call] { lock.withLock { recorded } }

    var currentExit: GuestExit? { lock.withLock { exit } }

    /// Ends the machine now.
    func stop(with exit: GuestExit = GuestExit(exitCode: 0)) {
        let resumed = lock.withLock { () -> [CheckedContinuation<GuestExit, Never>] in
            if self.exit == nil { self.exit = exit }
            defer { waiters = [] }
            return waiters
        }
        for waiter in resumed { waiter.resume(returning: exit) }
    }

    /// Ends the machine when `call` arrives.
    func stopOn(_ call: Call, exit: GuestExit = GuestExit(exitCode: 0)) {
        lock.withLock { stopTrigger = (call, exit) }
    }

    /// Makes `requestStop` throw, as it does on a guest that cannot take the request.
    func failRequestStop() { lock.withLock { _ = failing.insert("requestStop") } }

    /// Makes `forceStop` throw, for the next `times` calls.
    func failForceStop(times: Int = .max) { lock.withLock { forceStopFailures = times } }

    /// Makes `forceStop` wait, after it recorded the call, until the returned gate opens or fails.
    func suspendForceStop() -> Gate {
        let gate = Gate()
        lock.withLock { forceStopGate = gate }
        return gate
    }

    /// Makes `start` wait, after it recorded the call, until the returned gate opens or fails.
    func suspendStart() -> Gate {
        let gate = Gate()
        lock.withLock { startGate = gate }
        return gate
    }

    /// Makes `start` throw `error`, after the gate if there is one; nil makes it succeed again.
    func failStart(with error: (any Error)?) { lock.withLock { startError = error } }

    private func record(_ call: Call) {
        let trigger = lock.withLock { () -> GuestExit? in
            recorded.append(call)
            return stopTrigger?.call == call ? stopTrigger?.exit : nil
        }
        if let trigger { stop(with: trigger) }
    }

    func start() async throws {
        record(.start)
        try await lock.withLock { startGate }?.pass()
        if let error = lock.withLock({ startError }) { throw error }
    }

    func requestStop() async throws {
        record(.requestStop)
        if lock.withLock({ failing.contains("requestStop") }) { throw Refused() }
    }

    func forceStop() async throws {
        record(.forceStop)
        try await lock.withLock { forceStopGate }?.pass()
        let fails = lock.withLock { () -> Bool in
            guard forceStopFailures > 0 else { return false }
            forceStopFailures -= 1
            return true
        }
        if fails { throw Refused() }
    }

    func wait() async -> GuestExit {
        record(.wait)
        return await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> GuestExit? in
                if let exit { return exit }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func wait(timeout: Duration) async -> GuestExit? {
        record(.waitWithTimeout(timeout))
        return currentExit
    }
}
