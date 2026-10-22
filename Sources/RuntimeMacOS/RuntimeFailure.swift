// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError

/// A failure with a known cause and remedy, shared by the plugin and the `parbake` tool.
public enum RuntimeFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case lockHeld(path: String, holder: String?)
    case dhcpTimeout(macAddress: String, seconds: Int, leaseFile: String)
    case sshTimeout(username: String, address: String, seconds: Int)
    case agentTimeout(seconds: Int, label: String?)
    case keychainLocked(service: String)
    case keychainRefused(service: String, status: Int32)
    case bundleMissing(path: String, missing: String?)
    case restoreImageMissing(path: String)
    case vmLimitReached

    public var description: String {
        switch self {
        case .lockHeld(let path, let holder):
            let by = holder.map { " (\($0))" } ?? ""
            return "\(path) is in use by another process\(by); wait for it to finish, or remove the lock file if that process is gone."
        case .dhcpTimeout(let macAddress, let seconds, let leaseFile):
            return "the guest with MAC address \(macAddress) got no DHCP lease within \(seconds) seconds; check \(leaseFile) and that the guest finished booting."
        case .sshTimeout(let username, let address, let seconds):
            return "\(username)@\(address) did not answer over SSH within \(seconds) seconds; check that Remote Login is enabled in the guest."
        case .agentTimeout(let seconds, let label):
            let setting = label.map { " or raise the container's \($0) label" } ?? ""
            return "the guest agent did not answer within \(seconds) seconds; run `parbake agent-probe` to check it\(setting)."
        case .keychainLocked(let service):
            return "the keychain item for \(service) is not available because the login keychain is locked; unlock the login keychain, and log in to a GUI session on this host."
        case .keychainRefused(let service, let status):
            return "the keychain refused access to \(service) (status \(status)); allow it in Keychain Access, or remove the item and retry."
        case .bundleMissing(let path, let missing):
            let what = missing.map { "\($0) is missing from" } ?? "there is no VM bundle at"
            return "\(what) \(path); create the bundle with `parbake create`."
        case .restoreImageMissing(let path):
            return "there is no restore image at \(path); pass an existing file, or an http(s) URL to download, to --restore-image."
        case .vmLimitReached:
            return "the host already runs two macOS guests, the Virtualization.framework limit; stop one and retry. If none is running, a slot leaked: reboot the host."
        }
    }

    /// The `parbake` exit code for this failure.
    public var exitCode: Int32 {
        switch self {
        case .lockHeld, .dhcpTimeout, .sshTimeout, .agentTimeout: 75
        case .keychainLocked, .keychainRefused, .vmLimitReached: 69
        case .bundleMissing, .restoreImageMissing: 66
        }
    }

    public var containerizationCode: ContainerizationError.Code {
        switch self {
        case .lockHeld, .keychainLocked, .keychainRefused: .invalidState
        case .dhcpTimeout, .sshTimeout, .agentTimeout: .timeout
        case .bundleMissing, .restoreImageMissing: .notFound
        case .vmLimitReached: .unsupported
        }
    }
}
