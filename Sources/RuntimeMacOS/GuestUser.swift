// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationOCI

/// The account a process in the guest runs as, as `container exec` names it.
public enum GuestUser: Sendable, Equatable {
    /// `--user <name>`.
    case name(String)
    /// `--uid`/`--gid`, and what `container exec` sends without `--user`: the init process's
    /// user, uid 0 and gid 0.
    case id(uid: UInt32, gid: UInt32)

    /// The OCI user the agent starts the process as.
    ///
    /// uid 0 with gid 0 becomes the provisioned account, because a macOS job needs that account's
    /// session for the keychain, signing and simulators; root is `--user root`. Without a
    /// provisioned account the process runs as root.
    public func ociUser(provisionedUsername: String?, additionalGids: [UInt32] = []) -> ContainerizationOCI.User {
        switch self {
        case .name(let name):
            return User(uid: 0, gid: 0, additionalGids: additionalGids, username: name)
        case .id(uid: 0, gid: 0):
            guard let provisionedUsername else {
                return User(uid: 0, gid: 0, additionalGids: additionalGids)
            }
            return User(uid: 0, gid: 0, additionalGids: additionalGids, username: provisionedUsername)
        case .id(let uid, let gid):
            return User(uid: uid, gid: gid, additionalGids: additionalGids)
        }
    }
}
