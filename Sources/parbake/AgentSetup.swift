// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Darwin
import Foundation
import RuntimeMacOS

/// The host's part of installing the guest agent, shared by `provision` and `agent install`.
enum AgentSetup {
    /// The agent executable at `path`, or the one built next to `parbake`.
    static func binary(at path: String?) throws -> Data {
        let url = ProvisionInputs.agentURL(path)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ParbakeError.runtime("no agent executable at \(url.path); pass --agent")
        }
        return data
    }

    /// Leaves `binary` at `GuestAgentInstallation.stagedPath` in the guest.
    static func stage(_ binary: Data, shell: GuestShell, address: String) async throws {
        let result = await shell.run(GuestAgentInstallation.stageCommand, on: address, input: binary)
        guard result.status == 0 else {
            throw ParbakeError.runtime("copying the agent into the guest failed: \(LogText.sanitized(result.errorOutput))")
        }
    }

    /// Waits until the installed agent answers over vsock, records its version in the bundle's
    /// `Agent` file, and shuts the guest down through it; returns whether the guest accepted the
    /// shutdown.
    static func confirmAndShutDown(virtualMachine: MacOSVirtualMachine, bundle: MacOSVMBundle) async throws -> Bool {
        let agent = GuestAgent(virtualMachine: virtualMachine)
        let version = try await agent.waitUntilReady(timeout: GuestAgentInstallation.readinessTimeout)
        try Data((version + "\n").utf8).write(to: bundle.agentURL)
        print("The guest agent answers over vsock with version \(version)")
        let accepted = await agent.shutDown(provisionedUsername: bundle.provisionedUsername, timeout: .seconds(15)) { print($0) }
        await agent.close()
        return accepted
    }

    /// Waits for a guest whose shutdown is under way to stop, asks it like the power button after
    /// `timeout`, and stops it forcibly a minute later.
    static func waitForStop(_ virtualMachine: MacOSVirtualMachine, timeout: Duration = .seconds(180)) async throws {
        var forceStopFailed = false
        let outcome = await GuestShutdown.run(
            virtualMachine, request: { true }, requestWait: timeout, powerButtonWait: .seconds(60),
            note: { step, error in
                forceStopFailed = forceStopFailed || step == .forceStop
                reportStopFailure(step, error)
            })
        if forceStopFailed {
            throw ParbakeError.runtime("the guest did not shut down and may still be running")
        }
        if outcome == .forced {
            throw ParbakeError.runtime("the guest did not shut down; it was stopped forcibly and may need another boot")
        }
    }

    /// Prints a failed step of `GuestShutdown.run` to standard error.
    static func reportStopFailure(_ step: GuestShutdown.Step, _ error: any Error) {
        let text =
            switch step {
            case .requestStop: "the guest rejected the stop request"
            case .forceStop: "could not stop the guest forcibly"
            }
        FileHandle.standardError.write(Data("\(text): \(RuntimeLifecycle.containerizationError(from: error))\n".utf8))
    }

    /// Waits until the account answers over SSH and returns the address that answered.
    ///
    /// `onProbeError` sees each failed attempt once the guest has a lease.
    static func waitForSSH(
        _ virtualMachine: MacOSVirtualMachine, shell: GuestShell, timeout: Int, onProbeError: (ProbeError) -> Void = { _ in }
    ) async throws -> String {
        do {
            return try await GuestReachability.waitForSSH(
                username: shell.username, macAddress: virtualMachine.macAddress, leaseFile: DHCPLeases.path, timeout: .seconds(timeout),
                guestExited: { virtualMachine.currentExit }, lease: { DHCPLeases.currentAddress(for: virtualMachine.macAddress) },
                reach: { address in
                    let result = await shell.run("true", on: address)
                    return result.status == 0 ? .success(()) : .failure(ProbeError(LogText.sanitized(result.errorOutput)))
                }, onProbeError: onProbeError)
        } catch {
            throw ParbakeError.failure(error)
        }
    }

    /// The account password from the login keychain with `keychainService`, or from standard
    /// input, or prompted for on a terminal.
    static func password(for username: String, keychainService: String?) async throws -> String {
        if let keychainService {
            guard let password = try await GuestCredentials(service: keychainService).password(for: username) else {
                throw ParbakeError.runtime("the keychain has no password for \(username) under \(keychainService)")
            }
            return password
        }
        return try promptedPassword(for: username)
    }

    /// The account password from standard input, or prompted for on a terminal.
    static func promptedPassword(for username: String) throws -> String {
        if isatty(STDIN_FILENO) != 0 {
            var buffer = [CChar](repeating: 0, count: 1024)
            guard let line = readpassphrase("Password for \(username): ", &buffer, buffer.count, 0) else {
                throw ParbakeError.runtime("failed to read the password")
            }
            return String(cString: line)
        }
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            throw ParbakeError.runtime("no password on standard input")
        }
        return line
    }
}
