// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import RuntimeMacOS

/// The checks that run before `create` downloads anything and before `provision` boots the guest.
struct ProvisionInputs {
    /// Throws a `ValidationError` for the first input that is unusable, and the keychain preflight's
    /// failure when `keychain` is set and the keychain refuses.
    static func validate(
        username: String, authorizedKeys: [URL], sudo: [String], agent: String?, noAgent: Bool,
        scripts: [URL], keychain: Bool, keychainService: String,
        keychainPreflight: (String) throws -> Void = { try GuestCredentials(service: $0).preflight() }
    ) throws {
        guard GuestUsername(rawValue: username) != nil else {
            throw ValidationError("the username must be \(GuestUsername.rule)")
        }
        for url in authorizedKeys {
            try checkKey(at: url)
        }
        for command in sudo {
            do {
                try GuestPreparation.checkSudoCommand(command)
            } catch {
                throw ValidationError("\(error)")
            }
        }
        if noAgent {
            guard agent == nil else {
                throw ValidationError("--agent and --no-agent conflict")
            }
        } else {
            let binary = agentURL(agent)
            guard FileManager.default.isReadableFile(atPath: binary.path) else {
                throw ValidationError("no agent executable at \(binary.path); pass --agent or --no-agent")
            }
        }
        for script in scripts {
            guard FileManager.default.isReadableFile(atPath: script.path) else {
                throw ValidationError("cannot read the script \(script.path)")
            }
        }
        if keychain {
            try keychainPreflight(keychainService)
        }
    }

    /// Refuses account flags given without `--username`.
    static func checkAccountFlags(
        username: String?, authorizedKeys: [String], sudo: [String], keychain: Bool, fullName: String?, tidy: Bool
    ) throws {
        guard username == nil else { return }
        let given = [
            (!authorizedKeys.isEmpty, "--authorized-key"), (!sudo.isEmpty, "--sudo"), (keychain, "--keychain"),
            (fullName != nil, "--full-name"), (tidy, "--tidy"),
        ].filter(\.0).map(\.1)
        if !given.isEmpty {
            throw ValidationError("\(given.joined(separator: ", ")) need --username")
        }
    }

    /// `path`, or the `parbake-agent` next to the running executable.
    static func agentURL(_ path: String?) -> URL {
        if let path { return URL(fileURLWithPath: path) }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("parbake-agent")
    }

    private static func checkKey(at url: URL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ValidationError("cannot read the public key file \(url.path)")
        }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n") else {
            throw ValidationError("\(url.path) must hold one public key on one line")
        }
        do {
            try ScriptInput.check(key, field: "public key in \(url.path)")
        } catch {
            throw ValidationError("\(error)")
        }
    }
}
