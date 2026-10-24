// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

struct GuestShutdownTests {
    private let requestWait = Duration.seconds(30)
    private let buttonWait = Duration.seconds(10)

    private func run(_ fake: FakeGuestMachine, accepted: Bool, onRequest: @Sendable () -> Void = {}) async -> (GuestShutdown.Outcome, Int) {
        let counter = Counter()
        let outcome = await GuestShutdown.run(
            fake, request: { counter.increment(); onRequest(); return accepted }, requestWait: requestWait, powerButtonWait: buttonWait)
        return (outcome, counter.value)
    }

    @Test
    func testAcceptedRequestThatStopsTheGuestEndsTheLadder() async {
        let fake = FakeGuestMachine()
        let (outcome, _) = await run(fake, accepted: true) { fake.stop() }
        #expect(outcome == .stoppedAfterRequest)
        #expect(fake.calls == [.waitWithTimeout(requestWait)])
    }

    @Test
    func testRefusedRequestPressesThePowerButton() async {
        let fake = FakeGuestMachine()
        fake.stopOn(.requestStop)
        let (outcome, _) = await run(fake, accepted: false)
        #expect(outcome == .stoppedAfterPowerButton)
        #expect(fake.calls == [.requestStop, .waitWithTimeout(buttonWait)])
    }

    @Test
    func testAcceptedRequestThatDoesNotStopTheGuestFallsBackToThePowerButton() async {
        let fake = FakeGuestMachine()
        fake.stopOn(.requestStop)
        let (outcome, _) = await run(fake, accepted: true)
        #expect(outcome == .stoppedAfterPowerButton)
        #expect(fake.calls == [.waitWithTimeout(requestWait), .requestStop, .waitWithTimeout(buttonWait)])
    }

    @Test
    func testAGuestThatIgnoresEverythingIsForced() async {
        let fake = FakeGuestMachine()
        fake.stopOn(.forceStop, exit: GuestExit(exitCode: 137))
        let (outcome, _) = await run(fake, accepted: true)
        #expect(outcome == .forced)
        #expect(fake.calls == [.waitWithTimeout(requestWait), .requestStop, .waitWithTimeout(buttonWait), .forceStop])
    }

    @Test
    func testAGuestThatStoppedAlreadyIsNotTouched() async {
        let fake = FakeGuestMachine(exit: GuestExit(exitCode: 0))
        let (outcome, requests) = await run(fake, accepted: true)
        #expect(outcome == .stoppedAfterRequest)
        #expect(requests == 0)
        #expect(fake.calls.isEmpty)
    }

    @Test
    func testAGuestThatStoppedDuringARefusedRequestGetsNoPowerButton() async {
        let fake = FakeGuestMachine()
        let (outcome, _) = await run(fake, accepted: false) { fake.stop() }
        #expect(outcome == .stoppedAfterRequest)
        #expect(fake.calls.isEmpty)
    }

    @Test
    func testAFailingPowerButtonRequestOnAStoppedGuestCountsAsStopped() async {
        let fake = FakeGuestMachine()
        fake.failRequestStop()
        fake.stopOn(.requestStop)
        let noted = Notes()
        let outcome = await GuestShutdown.run(
            fake, request: { false }, requestWait: requestWait, powerButtonWait: buttonWait,
            note: { step, error in noted.append(step, error) })
        #expect(outcome == .stoppedAfterPowerButton)
        #expect(fake.calls == [.requestStop, .waitWithTimeout(buttonWait)])
        #expect(noted.steps.isEmpty)
    }

    @Test
    func testAFailedPowerButtonRequestAndForceStopAreNoted() async {
        let fake = FakeGuestMachine()
        fake.failRequestStop()
        fake.failForceStop()
        let noted = Notes()
        let outcome = await GuestShutdown.run(
            fake, request: { false }, requestWait: requestWait, powerButtonWait: buttonWait,
            note: { step, error in noted.append(step, error) })
        #expect(outcome == .forced)
        #expect(noted.steps == [.requestStop, .forceStop])
        #expect(noted.errors.count == 2)
        #expect(noted.errors.allSatisfy { $0 is FakeGuestMachine.Refused })
    }

    @Test
    func testALadderWhoseStepsSucceedNotesNothing() async {
        let fake = FakeGuestMachine()
        fake.stopOn(.forceStop)
        let noted = Notes()
        let outcome = await GuestShutdown.run(
            fake, request: { false }, requestWait: requestWait, powerButtonWait: buttonWait,
            note: { step, error in noted.append(step, error) })
        #expect(outcome == .forced)
        #expect(noted.steps.isEmpty)
    }

    @Test
    func testAFailingForceStopStillEndsTheLadder() async {
        let fake = FakeGuestMachine()
        fake.failRequestStop()
        fake.failForceStop()
        let (outcome, _) = await run(fake, accepted: false)
        #expect(outcome == .forced)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var noted: [(GuestShutdown.Step, any Error)] = []
    func append(_ step: GuestShutdown.Step, _ error: any Error) { lock.withLock { noted.append((step, error)) } }
    var steps: [GuestShutdown.Step] { lock.withLock { noted.map(\.0) } }
    var errors: [any Error] { lock.withLock { noted.map(\.1) } }
}
