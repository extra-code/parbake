// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import Virtualization

@testable import RuntimeMacOS

/// An error that names itself as its underlying error.
///
/// `NSError` is `@unchecked Sendable`, and a subclass must restate it; this one adds no stored state.
private final class SelfWrappingError: NSError, @unchecked Sendable {
    override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}

struct MacOSVirtualMachineTests {
    @Test
    func testTheVMLimitMapsToVMLimitReached() {
        let mapped = MacOSVirtualMachine.mapStartError(VZError(.virtualMachineLimitExceeded))
        #expect(mapped as? RuntimeFailure == .vmLimitReached)
    }

    @Test
    func testAWrappedVMLimitMapsToVMLimitReached() {
        let outer = NSError(domain: VZError.errorDomain, code: VZError.Code.internalError.rawValue, userInfo: [NSUnderlyingErrorKey: VZError(.virtualMachineLimitExceeded)])
        #expect(MacOSVirtualMachine.mapStartError(outer) as? RuntimeFailure == .vmLimitReached)
    }

    @Test
    func testALockContentionErrorIsReturnedUnchanged() {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
        let outer = NSError(domain: VZError.errorDomain, code: VZError.Code.internalError.rawValue, userInfo: [NSUnderlyingErrorKey: inner])
        let mapped = MacOSVirtualMachine.mapStartError(outer)
        #expect(mapped as? RuntimeFailure == nil)
        #expect((mapped as NSError) === outer)
        #expect(MacOSVirtualMachine.isLockContention(mapped))
    }

    @Test
    func testOtherVZErrorsAreReturnedUnchanged() {
        let error = VZError(.invalidVirtualMachineConfiguration)
        let mapped = MacOSVirtualMachine.mapStartError(error)
        #expect(mapped as? RuntimeFailure == nil)
        #expect((mapped as? VZError)?.code == .invalidVirtualMachineConfiguration)
    }

    @Test
    func testAnErrorThatWrapsItselfEndsTheWalk() {
        let error = SelfWrappingError(domain: "test", code: 1)
        #expect(!MacOSVirtualMachine.isLockContention(error))
        #expect(MacOSVirtualMachine.mapStartError(error) as? RuntimeFailure == nil)
    }

    /// A request below, inside and above the range, for the cpus (range 2...8) and for the memory
    /// (range 1 GiB...64 GiB, with the runtime's own floor of 4 GiB).
    @Test(arguments: [
        (cpus: 1, expected: 2), (cpus: 2, expected: 2), (cpus: 5, expected: 5), (cpus: 8, expected: 8), (cpus: 12, expected: 8),
    ])
    func testTheCpuCountIsClampedToTheRange(cpus: Int, expected: Int) {
        let granted = MacOSVirtualMachine.resources(
            cpus: cpus, memoryInBytes: 8 << 30, minimum: (2, 1 << 30), maximum: (8, 64 << 30))
        #expect(granted.cpus == expected)
    }

    @Test(arguments: [
        (memory: UInt64(1 << 30), expected: UInt64(4 << 30)), (memory: UInt64(4 << 30), expected: UInt64(4 << 30)),
        (memory: UInt64(10 << 30), expected: UInt64(10 << 30)), (memory: UInt64(64 << 30), expected: UInt64(64 << 30)),
        (memory: UInt64(100 << 30), expected: UInt64(64 << 30)),
    ])
    func testTheMemoryIsRaisedToTheFloorAndClampedToTheRange(memory: UInt64, expected: UInt64) {
        let granted = MacOSVirtualMachine.resources(
            cpus: 4, memoryInBytes: memory, minimum: (2, 1 << 30), maximum: (8, 64 << 30))
        #expect(granted.memory == expected)
    }

    @Test
    func testAHostMinimumAboveTheRuntimeFloorWins() {
        let granted = MacOSVirtualMachine.resources(cpus: 4, memoryInBytes: 1 << 30, minimum: (2, 6 << 30), maximum: (8, 64 << 30))
        #expect(granted.memory == 6 << 30)
    }

    @Test
    func testAHostMaximumBelowTheRuntimeFloorWins() {
        let granted = MacOSVirtualMachine.resources(cpus: 4, memoryInBytes: 8 << 30, minimum: (2, 1 << 30), maximum: (8, 3 << 30))
        #expect(granted.memory == 3 << 30)
    }

    @Test
    func testALockHeldByAnotherProcessIsRetriedUntilTheStartSucceeds() async throws {
        let attempts = Counter()
        try await MacOSVirtualMachine.retryOnLockContention(
            path: "/aux", timeout: .seconds(30), every: .seconds(2), sleep: noSleep
        ) {
            if attempts.next() <= 2 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
            }
        }
        #expect(attempts.count == 3)
    }

    @Test
    func testALockThatStaysHeldEndsInLockHeld() async {
        let attempts = Counter()
        let clock = FakeClock()
        let advance: @Sendable (Duration) async throws -> Void = { clock.advance($0) }
        let current: @Sendable () -> ContinuousClock.Instant = { clock.now }
        await #expect(throws: RuntimeFailure.lockHeld(path: "/aux", holder: nil)) {
            try await MacOSVirtualMachine.retryOnLockContention(
                path: "/aux", timeout: .seconds(30), every: .seconds(2), sleep: advance, now: current
            ) {
                _ = attempts.next()
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
            }
        }
        #expect(attempts.count == 16)
    }

    @Test
    func testAnotherStartErrorFailsAtOnce() async {
        let attempts = Counter()
        await #expect(throws: RuntimeFailure.vmLimitReached) {
            try await MacOSVirtualMachine.retryOnLockContention(path: "/aux", timeout: .seconds(30), every: .seconds(2), sleep: noSleep) {
                _ = attempts.next()
                throw VZError(.virtualMachineLimitExceeded)
            }
        }
        #expect(attempts.count == 1)
    }
}

private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}
