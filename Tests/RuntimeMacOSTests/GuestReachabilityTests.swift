// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

/// A clock the injected sleep advances, so no test waits.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var elapsed = Duration.zero
    private var slept: [Duration] = []

    var now: ContinuousClock.Instant { lock.withLock { base.advanced(by: elapsed) } }
    var sleeps: [Duration] { lock.withLock { slept } }

    func sleep(_ duration: Duration) {
        lock.withLock {
            elapsed += duration
            slept.append(duration)
        }
    }
}

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

struct GuestReachabilityTests {
    private func wait(
        timeout: Duration = .seconds(30), clock: TestClock, exited: @escaping () -> GuestExit? = { nil }, lease: @escaping () -> String? = { "192.168.64.3" },
        reach: @escaping (String) async -> Result<Void, ProbeError>, onProbeError: @escaping (ProbeError) -> Void = { _ in }
    ) async throws(RuntimeFailure) -> String {
        try await GuestReachability.waitForSSH(
            username: "ci", macAddress: "aa:bb:cc:dd:ee:ff", leaseFile: "/leases", every: .seconds(3), timeout: timeout, guestExited: exited,
            lease: lease, reach: reach, onProbeError: onProbeError, sleep: { clock.sleep($0) }, now: { clock.now })
    }

    @Test
    func testPollReturnsAtOnceWhenTheFirstProbeAnswers() async throws {
        let clock = TestClock()
        let value = try await GuestReachability.poll(every: .seconds(1), timeout: .seconds(10), sleep: { clock.sleep($0) }, now: { clock.now }) { 7 }
        #expect(value == 7)
        #expect(clock.sleeps.isEmpty)
    }

    @Test
    func testPollAnswersOnTheThirdProbe() async throws {
        let clock = TestClock()
        let tally = Tally()
        let value = try await GuestReachability.poll(every: .seconds(2), timeout: .seconds(10), sleep: { clock.sleep($0) }, now: { clock.now }) {
            () async throws -> Int? in
            tally.add("probe")
            return tally.all.count == 3 ? 3 : nil
        }
        #expect(value == 3)
        #expect(clock.sleeps == [.seconds(2), .seconds(2)])
    }

    @Test
    func testPollReturnsNilWhenTheTimeoutPasses() async throws {
        let clock = TestClock()
        let tally = Tally()
        let value = try await GuestReachability.poll(every: .seconds(3), timeout: .seconds(10), sleep: { clock.sleep($0) }, now: { clock.now }) {
            () async throws -> Int? in
            tally.add("probe")
            return nil
        }
        #expect(value == nil)
        #expect(tally.all.count == 5)
    }

    @Test
    func testPollProbesAtTheDeadlineAndNotPastIt() async throws {
        let clock = TestClock()
        let tally = Tally()
        let value = try await GuestReachability.poll(every: .seconds(2), timeout: .seconds(30), sleep: { clock.sleep($0) }, now: { clock.now }) {
            () async throws -> Int? in
            tally.add("probe")
            return nil
        }
        #expect(value == nil)
        #expect(tally.all.count == 16)
        #expect(clock.sleeps.count == 15)
    }

    @Test
    func testPollClampsTheLastSleepToTheDeadline() async throws {
        let clock = TestClock()
        let start = clock.now
        let tally = Tally()
        let value = try await GuestReachability.poll(every: .seconds(3), timeout: .seconds(10), sleep: { clock.sleep($0) }, now: { clock.now }) {
            () async throws -> Int? in
            tally.add("probe")
            return nil
        }
        #expect(value == nil)
        #expect(clock.sleeps == [.seconds(3), .seconds(3), .seconds(3), .seconds(1)])
        #expect(tally.all.count == 5)
        #expect(clock.now == start.advanced(by: .seconds(10)))
    }

    @Test
    func testPollWithNoTimeoutProbesOnce() async throws {
        let clock = TestClock()
        let tally = Tally()
        let value = try await GuestReachability.poll(every: .seconds(2), timeout: .zero, sleep: { clock.sleep($0) }, now: { clock.now }) {
            () async throws -> Int? in
            tally.add("probe")
            return nil
        }
        #expect(value == nil)
        #expect(tally.all.count == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test
    func testPollPropagatesProbeErrors() async {
        let clock = TestClock()
        await #expect(throws: ProbeError.self) {
            let _: Int? = try await GuestReachability.poll(every: .seconds(1), timeout: .seconds(10), sleep: { clock.sleep($0) }, now: { clock.now }) {
                throw ProbeError("boom")
            }
        }
    }

    @Test
    func testWaitForSSHReturnsTheAddressThatAnswered() async throws {
        let clock = TestClock()
        let address = try await wait(clock: clock, reach: { _ in .success(()) })
        #expect(address == "192.168.64.3")
        #expect(clock.sleeps.isEmpty)
    }

    @Test
    func testWaitForSSHSucceedsOnTheThirdProbeAndReportsEachFailure() async throws {
        let clock = TestClock()
        let attempts = Tally()
        let errors = Tally()
        let address = try await wait(
            clock: clock,
            reach: { _ in
                attempts.add("try")
                return attempts.all.count < 3 ? .failure(ProbeError("refused \(attempts.all.count)")) : .success(())
            }, onProbeError: { errors.add($0.description) })
        #expect(address == "192.168.64.3")
        #expect(errors.all == ["refused 1", "refused 2"])
    }

    @Test
    func testSSHTimeoutNamesTheLastAddress() async {
        let clock = TestClock()
        await #expect(throws: RuntimeFailure.sshTimeout(username: "ci", address: "192.168.64.3", seconds: 10)) {
            _ = try await wait(timeout: .seconds(10), clock: clock, reach: { _ in .failure(ProbeError("no")) })
        }
    }

    @Test
    func testDHCPTimeoutWhenTheGuestNeverHadALease() async {
        let clock = TestClock()
        await #expect(throws: RuntimeFailure.dhcpTimeout(macAddress: "aa:bb:cc:dd:ee:ff", seconds: 10, leaseFile: "/leases")) {
            _ = try await wait(timeout: .seconds(10), clock: clock, lease: { nil }, reach: { _ in .success(()) })
        }
    }

    @Test
    func testGuestExitStopsTheWaitAtTheNextProbe() async {
        let clock = TestClock()
        let probes = Tally()
        await #expect(throws: RuntimeFailure.guestStopped(exitCode: 1)) {
            _ = try await wait(
                clock: clock, exited: { probes.all.count >= 2 ? GuestExit(exitCode: 1) : nil },
                reach: { _ in
                    probes.add("try")
                    return .failure(ProbeError("no"))
                })
        }
        #expect(probes.all.count == 2)
    }

    @Test
    func testACancelledSleepEndsTheWaitAsInterrupted() async {
        let clock = TestClock()
        await #expect(throws: RuntimeFailure.interrupted("waiting for the guest was interrupted")) {
            _ = try await GuestReachability.waitForSSH(
                username: "ci", macAddress: "aa:bb:cc:dd:ee:ff", leaseFile: "/leases", every: .seconds(3), timeout: .seconds(30), guestExited: { nil },
                lease: { "192.168.64.3" }, reach: { _ in .failure(ProbeError("no")) }, onProbeError: { _ in }, sleep: { _ in throw CancellationError() },
                now: { clock.now })
        }
    }
}
