// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

public enum SigningIdentity: Equatable, Sendable {
    case adHoc
    case team(String)

    /// The code signature of the running process: `.team` when it carries a team identifier, else `.adHoc`.
    public static func ofCurrentProcess() -> SigningIdentity {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return .adHoc }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return .adHoc }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let dictionary = information as? [String: Any],
            let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            !team.isEmpty
        else { return .adHoc }
        return .team(team)
    }
}

public enum KeychainAccess: Equatable, Sendable {
    /// Created by `security -i add-generic-password -A`; read and deleted through `security -i`.
    case anyApplication
    /// Created, read and deleted in-process (SecItemAdd/SecItemCopyMatching/SecItemDelete).
    case creatorOnly

    /// A team identity gets `.creatorOnly`; an ad-hoc one, or any identity while `restrictsWithStableIdentity` is false, gets `.anyApplication`.
    public static func `for`(_ identity: SigningIdentity) -> KeychainAccess {
        guard restrictsWithStableIdentity else { return .anyApplication }
        switch identity {
        case .adHoc: return .anyApplication
        case .team: return .creatorOnly
        }
    }

    public static let restrictsWithStableIdentity = true
}
