// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

@Suite(.timeLimit(.minutes(1)))
struct ExitLatchTests {
    /// Starts `count` tasks that each report their arrival right before they call `body`, and returns once all arrived.
    private func startWaiters<T: Sendable>(
        _ count: Int, _ body: @escaping @Sendable () async -> T
    ) async -> [Task<T, Never>] {
        let (arrivals, arrived) = AsyncStream.makeStream(of: Void.self)
        let tasks = (0..<count).map { _ in
            Task {
                arrived.yield()
                return await body()
            }
        }
        var seen = 0
        for await _ in arrivals {
            seen += 1
            if seen == count { break }
        }
        return tasks
    }

    @Test
    func testWaitAfterFinishReturnsTheExit() async {
        let latch = ExitLatch()
        latch.finish(exitCode: 3)
        #expect(await latch.wait().exitCode == 3)
        #expect(latch.current?.exitCode == 3)
    }

    @Test
    func testWaitBeforeFinishReturnsWhenFinished() async {
        let latch = ExitLatch()
        let waiters = await startWaiters(1) { await latch.wait() }
        latch.finish(exitCode: 7)
        #expect(await waiters[0].value.exitCode == 7)
    }

    @Test
    func testSeveralWaitersAllResume() async {
        let latch = ExitLatch()
        let waiters = await startWaiters(5) { await latch.wait().exitCode }
        latch.finish(exitCode: 9)
        var codes: [Int32] = []
        for waiter in waiters { codes.append(await waiter.value) }
        #expect(codes == [9, 9, 9, 9, 9])
    }

    @Test
    func testTheTimeoutReturnsNilWhileTheGuestRuns() async {
        let latch = ExitLatch()
        #expect(await latch.wait(timeout: .zero) == nil)
        #expect(latch.current == nil)
    }

    @Test
    func testFinishingDuringATimedWaitReturnsTheExit() async {
        let latch = ExitLatch()
        let waiters = await startWaiters(1) { await latch.wait(timeout: .seconds(60)) }
        latch.finish(exitCode: 5)
        #expect(await waiters[0].value?.exitCode == 5)
    }

    @Test
    func testTheTimedWaitReturnsTheExitOfAStoppedGuest() async {
        let latch = ExitLatch()
        latch.finish(exitCode: 2)
        #expect(await latch.wait(timeout: .seconds(60))?.exitCode == 2)
    }

    @Test
    func testASecondFinishIsIgnored() {
        let latch = ExitLatch()
        latch.finish(exitCode: 1)
        let first = latch.current
        latch.finish(exitCode: 2)
        #expect(latch.current == first)
        #expect(latch.current?.exitCode == 1)
    }
}
