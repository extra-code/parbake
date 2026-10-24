// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

/// The ladder that stops a guest: ask it, press the power button, then cut the power.
public enum GuestShutdown {
    public enum Outcome: Equatable, Sendable {
        /// The guest stopped after its shutdown was requested, or was already stopped.
        case stoppedAfterRequest
        /// The guest stopped after the power-button request.
        case stoppedAfterPowerButton
        /// The guest had to be stopped forcibly.
        case forced
    }

    /// A step of the ladder that can fail without ending it.
    public enum Step: Equatable, Sendable {
        /// The power-button request, `GuestMachine.requestStop`.
        case requestStop
        /// The forced stop, `GuestMachine.forceStop`.
        case forceStop
    }

    /// Stops `machine`.
    ///
    /// `request` asks the guest to shut itself down and returns whether it accepted. An accepted request gets
    /// `requestWait`; otherwise, or when the guest is still running, the power button gets `powerButtonWait`,
    /// and then the guest is stopped forcibly. A request that fails because the guest already stopped counts as
    /// a stop and is not noted. A failed power-button request or forced stop goes to `note` and the ladder goes on.
    public static func run(
        _ machine: any GuestMachine, request: () async -> Bool, requestWait: Duration, powerButtonWait: Duration,
        note: (Step, any Error) -> Void = { _, _ in }
    ) async -> Outcome {
        if machine.currentExit != nil { return .stoppedAfterRequest }
        if await request(), await machine.wait(timeout: requestWait) != nil {
            return .stoppedAfterRequest
        }
        if machine.currentExit != nil { return .stoppedAfterRequest }
        do {
            try await machine.requestStop()
        } catch {
            if machine.currentExit == nil { note(.requestStop, error) }
        }
        if await machine.wait(timeout: powerButtonWait) != nil {
            return .stoppedAfterPowerButton
        }
        do {
            try await machine.forceStop()
        } catch {
            note(.forceStop, error)
        }
        return .forced
    }
}
