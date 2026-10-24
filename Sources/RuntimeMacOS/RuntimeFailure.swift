// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import ParbakeVersion

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
    case guestStopped(exitCode: Int32?)
    case internalError(String)
    case bundlePath(BundlePathReason)
    case incompatibleOverlay(bundle: String, base: String, reason: String)
    case agentVersionMismatch(agentVersion: String)
    case processLost(id: String, cause: String)
    case invalidArgument(String)
    case invalidState(String)
    case notFound(String)
    case unsupported(String)
    case interrupted(String)
    case timeout(String)
    case exists(String)

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
        case .guestStopped(let exitCode):
            return exitCode.map { "the guest stopped with exit code \($0) before it answered; boot it again and check the guest's console" }
                ?? "the guest stopped before it answered; boot it again and check the guest's console"
        case .bundlePath(let reason):
            return reason.description
        case .incompatibleOverlay(let bundle, let base, let reason):
            return "the overlay in \(bundle) does not stack on \(base): \(reason)"
        case .agentVersionMismatch(let agentVersion):
            return "the guest agent reports version \"\(agentVersion)\", this runtime speaks protocol \(AgentVersionLine.protocolVersion); "
                + "update the agent with parbake agent install"
        case .processLost(let id, let cause):
            return "lost process \(id) in the guest: \(cause)"
        case .internalError(let message), .invalidArgument(let message), .invalidState(let message), .notFound(let message),
            .unsupported(let message), .interrupted(let message), .timeout(let message),
            .exists(let message):
            return message
        }
    }

    /// The `parbake` exit code for this failure.
    public var exitCode: Int32 {
        switch self {
        case .lockHeld, .dhcpTimeout, .sshTimeout, .agentTimeout: 75
        case .keychainLocked, .keychainRefused, .vmLimitReached: 69
        case .bundleMissing, .restoreImageMissing: 66
        case .guestStopped, .internalError, .bundlePath, .incompatibleOverlay, .agentVersionMismatch, .processLost, .invalidArgument, .invalidState,
            .notFound, .unsupported, .interrupted, .timeout, .exists:
            1
        }
    }

    public var containerizationCode: ContainerizationError.Code {
        switch self {
        case .lockHeld, .keychainLocked, .keychainRefused, .incompatibleOverlay, .invalidState: .invalidState
        case .dhcpTimeout, .sshTimeout, .agentTimeout, .agentVersionMismatch, .timeout: .timeout
        case .bundleMissing, .restoreImageMissing, .notFound: .notFound
        case .vmLimitReached, .unsupported: .unsupported
        case .guestStopped, .processLost, .interrupted: .interrupted
        case .internalError: .internalError
        case .bundlePath, .invalidArgument: .invalidArgument
        case .exists: .exists
        }
    }
}

/// Why a bundle label or the bundle behind it was refused.
public enum BundlePathReason: Equatable, Sendable, CustomStringConvertible {
    case notAbsolute(String)
    case outsideRoots(path: String, roots: [String])
    case wrongOwner(path: String)
    case writableByOthers(path: String)
    case linkOutsideRoots(file: String, target: String)
    case badRootsFile(path: String, reason: String)

    public var description: String {
        switch self {
        case .notAbsolute(let path): "\(path) is not an absolute path"
        case .outsideRoots(let path, let roots):
            "\(path) is outside the allowed bundle directories (\(roots.joined(separator: ", "))); add its parent directory as an absolute path on its own line to ~/Library/Application Support/container-runtime-macos/bundle-roots"
        case .wrongOwner(let path): "\(path) is not owned by the current user; use a bundle you own"
        case .writableByOthers(let path): "\(path) is writable by other users; run chmod go-w on it"
        case .linkOutsideRoots(let file, let target): "\(file) links to \(target), outside the allowed bundle directories; link to a file inside them"
        case .badRootsFile(let path, let reason): "\(path): \(reason)"
        }
    }
}
