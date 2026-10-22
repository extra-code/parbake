// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Foundation
import Security

/// Guest account passwords in the host user's login keychain.
///
/// A CI host keeps the password of the guest's CI account here, so no person types it and no
/// configuration file holds it. Each password is a generic password item: the service names the
/// store, the account is the guest username.
///
/// With `.anyApplication` every access goes through `/usr/bin/security`, which creates the items
/// with `-A`. The items belong to that stable, Apple-signed tool, so a rebuilt or updated binary,
/// whose ad-hoc signature differs, never triggers a keychain dialog. Commands reach `security` on
/// standard input, so a password is in no argument list. A newline cannot be part of a password.
///
/// With `.creatorOnly` the Security framework creates, reads and deletes the items in this process;
/// the default access list admits the creating, signed binary only.
public struct GuestCredentials: Sendable {
    public static let defaultService = "container-runtime-macos.guest"

    /// The account of the reserved item `preflight()` looks up. It is never created.
    static let preflightAccount = "parbake-preflight"

    /// Printed when items are created open to every application.
    public static let adHocWarning =
        "this build is ad-hoc signed, so the keychain item is readable by every application of this user; "
        + "sign parbake with a team identity to restrict it to parbake."

    public let service: String
    public let access: KeychainAccess

    public init(service: String = Self.defaultService, access: KeychainAccess = .for(.ofCurrentProcess())) {
        self.service = service
        self.access = access
    }

    /// Probes the keychain with a lookup for a reserved account and creates nothing.
    ///
    /// A missing item counts as success; a locked or refusing keychain throws its classified failure.
    public func preflight() throws {
        switch access {
        case .anyApplication:
            let result = try Self.security(["find-generic-password", "-s", service, "-a", Self.preflightAccount])
            if result.status == 0 || result.status == Self.itemNotFoundStatus { return }
            throw Self.failure(result, service: service, "probe the keychain")
        case .creatorOnly:
            var query = baseQuery(account: Self.preflightAccount)
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecSuccess || status == errSecItemNotFound { return }
            throw Self.failure(status: status, service: service, "probe the keychain")
        }
    }

    /// The failure for a `security` or Security framework status that names a locked or refusing keychain, else nil.
    static func classify(status: Int32, errorOutput: String, service: String) -> RuntimeFailure? {
        if status == 0 || status == itemNotFoundStatus { return nil }
        let text = errorOutput.lowercased()
        if text.contains("user interaction is not allowed") || text.contains("\(errSecInteractionNotAllowed)") || status == errSecInteractionNotAllowed {
            return .keychainLocked(service: service)
        }
        if status == errSecAuthFailed || status == errSecUserCanceled || text.contains("\(errSecAuthFailed)") || text.contains("\(errSecUserCanceled)")
            || text.contains("authorization") || text.contains("denied")
        {
            return .keychainRefused(service: service, status: status)
        }
        return nil
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func failure(status: OSStatus, service: String, _ action: String) -> Error {
        if let failure = classify(status: status, errorOutput: "", service: service) { return failure }
        return ContainerizationError(.internalError, message: "failed to \(action): keychain status \(status)")
    }

    private static func failure(_ result: SecurityResult, service: String, _ action: String) -> Error {
        classify(status: result.status, errorOutput: result.errorOutput, service: service) ?? error(result, action)
    }

    /// The stored password for `username`, or nil when there is none.
    public func password(for username: String) throws -> String? {
        if access == .creatorOnly {
            try ScriptInput.check(service, field: "keychain service")
            try ScriptInput.check(username, field: "keychain account")
            var query = baseQuery(account: username)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data else {
                throw Self.failure(status: status, service: service, "read the password of \(username) from the keychain")
            }
            return String(decoding: data, as: UTF8.self)
        }
        let result = try Self.security(["find-generic-password", "-s", service, "-a", username, "-w"])
        if result.status == Self.itemNotFoundStatus {
            return nil
        }
        guard result.status == 0 else {
            throw Self.failure(result, service: service, "read the password of \(username) from the keychain")
        }
        return result.output.hasSuffix("\n") ? String(result.output.dropLast()) : result.output
    }

    /// Stores `password` for `username`, replacing a stored one.
    ///
    /// A stored item is deleted and added again: changing an item in place asks for permission.
    public func store(_ password: String, for username: String) throws {
        guard !password.contains("\n") else {
            throw ContainerizationError(.invalidArgument, message: "a keychain password cannot contain a newline")
        }
        try remove(for: username)
        if access == .creatorOnly {
            try ScriptInput.check(service, field: "keychain service")
            try ScriptInput.check(username, field: "keychain account")
            try ScriptInput.check(password, field: "keychain password")
            var query = baseQuery(account: username)
            query[kSecAttrLabel as String] = "\(service) (\(username))"
            query[kSecValueData as String] = Data(password.utf8)
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw Self.failure(status: status, service: service, "add the password of \(username) to the keychain")
            }
            return
        }
        let result = try Self.security([
            "add-generic-password", "-A",
            "-s", service,
            "-a", username,
            "-l", "\(service) (\(username))",
            "-w", password,
        ])
        guard result.status == 0 else {
            throw Self.failure(result, service: service, "add the password of \(username) to the keychain")
        }
    }

    /// Removes the stored password for `username`; a missing one is not an error.
    public func remove(for username: String) throws {
        if access == .creatorOnly {
            try ScriptInput.check(service, field: "keychain service")
            try ScriptInput.check(username, field: "keychain account")
            let status = SecItemDelete(baseQuery(account: username) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Self.failure(status: status, service: service, "remove the password of \(username) from the keychain")
            }
            return
        }
        let result = try Self.security(["delete-generic-password", "-s", service, "-a", username])
        guard result.status == 0 || result.status == Self.itemNotFoundStatus else {
            throw Self.failure(result, service: service, "remove the password of \(username) from the keychain")
        }
    }

    /// The stored password for `username`; generates and stores one when there is none.
    public func passwordCreatingIfNeeded(for username: String) throws -> String {
        if let password = try password(for: username) {
            return password
        }
        let password = try Self.generatePassword()
        try store(password, for: username)
        return password
    }

    /// A random password of `length` characters from letters and digits.
    public static func generatePassword(length: Int = 32) throws -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var password = ""
        while password.count < length {
            var bytes = [UInt8](repeating: 0, count: length)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw ContainerizationError(.internalError, message: "failed to generate a random password")
            }
            // Bytes past the largest multiple of the alphabet size would bias the choice.
            let limit = 256 - 256 % alphabet.count
            for byte in bytes where Int(byte) < limit && password.count < length {
                password.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return password
    }

    /// The exit status of `security` when no item matches.
    static let itemNotFoundStatus: Int32 = 44

    struct SecurityResult {
        let status: Int32
        let output: String
        let errorOutput: String
    }

    /// Runs one `security` command through its interactive mode, which exits with the command's status.
    static func security(_ arguments: [String]) throws -> SecurityResult {
        for argument in arguments {
            try ScriptInput.check(argument, field: "keychain argument")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let command = arguments.map(quoted).joined(separator: " ")
        stdin.fileHandleForWriting.write(Data((command + "\n").utf8))
        try? stdin.fileHandleForWriting.close()
        // Drains standard error on its own thread, so neither pipe fills while the other is read.
        nonisolated(unsafe) var errorData = Data()
        let errorReader = Thread { errorData = stderr.fileHandleForReading.readDataToEndOfFile() }
        errorReader.start()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        while !errorReader.isFinished { usleep(10_000) }
        return SecurityResult(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self),
            errorOutput: String(decoding: errorData, as: UTF8.self)
        )
    }

    /// `value` in double quotes for the interactive mode of `security`.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func error(_ result: SecurityResult, _ action: String) -> ContainerizationError {
        let reason = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContainerizationError(
            .internalError, message: "failed to \(action): \(reason.isEmpty ? "exit status \(result.status)" : reason)")
    }
}
