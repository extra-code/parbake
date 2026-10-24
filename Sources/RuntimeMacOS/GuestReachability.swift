// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

/// A failed attempt to reach a guest, with the reason to show.
public struct ProbeError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Waits for a guest to become reachable.
public enum GuestReachability {
    /// Calls `probe` at once and then every `every` until it returns a value or `timeout` passes.
    /// The last probe runs at the deadline, never after it.
    ///
    /// - Returns: The probe's value, or `nil` when the time ran out. Errors from `probe` and from `sleep` propagate.
    public static func poll<T: Sendable>(
        every: Duration, timeout: Duration,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @Sendable () -> ContinuousClock.Instant = { .now },
        _ probe: () async throws -> T?
    ) async throws -> T? {
        let deadline = now().advanced(by: timeout)
        while true {
            if let value = try await probe() { return value }
            let left = now().duration(to: deadline)
            if left <= .zero { return nil }
            try await sleep(min(every, left))
            if now() > deadline { return nil }
        }
    }

    /// Waits until the guest has a DHCP lease and answers over SSH, and returns the address that answered.
    ///
    /// `guestExited` is checked before each attempt; `reach` runs once the guest has a lease, and each of its
    /// failures goes to `onProbeError`.
    /// - Throws: `.guestStopped` when the guest exits; on timeout `.sshTimeout` naming the last address, or
    ///   `.dhcpTimeout` when the guest never had a lease.
    public static func waitForSSH(
        username: String, macAddress: String, leaseFile: String, every: Duration = .seconds(3), timeout: Duration,
        guestExited: () -> GuestExit?, lease: () -> String?, reach: (String) async -> Result<Void, ProbeError>,
        onProbeError: (ProbeError) -> Void = { _ in },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @Sendable () -> ContinuousClock.Instant = { .now }
    ) async throws(RuntimeFailure) -> String {
        var leased: String?
        do {
            let answered = try await poll(every: every, timeout: timeout, sleep: sleep, now: now) { () async throws -> String? in
                if let exit = guestExited() {
                    throw RuntimeFailure.guestStopped(exitCode: exit.exitCode)
                }
                guard let address = lease() else { return nil }
                leased = address
                switch await reach(address) {
                case .success: return address
                case .failure(let error):
                    onProbeError(error)
                    return nil
                }
            }
            if let answered { return answered }
        } catch let failure as RuntimeFailure {
            throw failure
        } catch is CancellationError {
            throw RuntimeFailure.interrupted("waiting for the guest was interrupted")
        } catch {
            throw RuntimeFailure.interrupted("waiting for the guest was interrupted: \(error)")
        }
        let seconds = Int(timeout.components.seconds)
        if let leased {
            throw .sshTimeout(username: username, address: leased, seconds: seconds)
        }
        throw .dhcpTimeout(macAddress: macAddress, seconds: seconds, leaseFile: leaseFile)
    }
}
