// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import TOMLDecoder

/// A bundle described in a TOML file for `parbake create --config`.
///
/// Every key is optional, and a key the file does not know is refused, so a misspelt key fails
/// instead of being ignored. Paths are relative to the file's directory, and `~` is the home
/// directory.
struct BundleConfiguration: Decodable, Equatable {
    var bundle: String?
    var restoreImage: String?
    var diskSize: UInt64?
    var cpus: Int?
    var memory: UInt64?
    var account: Account?
    var guest: Guest?

    struct Account: Decodable, Equatable {
        var username: String
        var fullName: String?
        var authorizedKeys: [String]?
        var keychain: Bool?
        var keychainService: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case username
            case fullName = "full-name"
            case authorizedKeys = "authorized-keys"
            case keychain
            case keychainService = "keychain-service"
        }

        init(from decoder: any Decoder) throws {
            try refuseUnknownKeys(in: decoder, known: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            username = try container.decode(String.self, forKey: .username)
            fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
            authorizedKeys = try container.decodeIfPresent([String].self, forKey: .authorizedKeys)
            keychain = try container.decodeIfPresent(Bool.self, forKey: .keychain)
            keychainService = try container.decodeIfPresent(String.self, forKey: .keychainService)
        }
    }

    struct Guest: Decodable, Equatable {
        var tidy: Bool?
        var agent: Bool?
        /// Commands the account may run with sudo and without a password, besides shutdown.
        var sudo: [String]?
        /// Shell scripts run as root through the agent after provisioning, in order.
        var scripts: [String]?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case tidy, agent, sudo, scripts
        }

        init(from decoder: any Decoder) throws {
            try refuseUnknownKeys(in: decoder, known: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tidy = try container.decodeIfPresent(Bool.self, forKey: .tidy)
            agent = try container.decodeIfPresent(Bool.self, forKey: .agent)
            sudo = try container.decodeIfPresent([String].self, forKey: .sudo)
            scripts = try container.decodeIfPresent([String].self, forKey: .scripts)
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case bundle
        case restoreImage = "restore-image"
        case diskSize = "disk-size"
        case cpus, memory, account, guest
    }

    init(from decoder: any Decoder) throws {
        try refuseUnknownKeys(in: decoder, known: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundle = try container.decodeIfPresent(String.self, forKey: .bundle)
        restoreImage = try container.decodeIfPresent(String.self, forKey: .restoreImage)
        diskSize = try container.decodeIfPresent(UInt64.self, forKey: .diskSize)
        cpus = try container.decodeIfPresent(Int.self, forKey: .cpus)
        memory = try container.decodeIfPresent(UInt64.self, forKey: .memory)
        account = try container.decodeIfPresent(Account.self, forKey: .account)
        guest = try container.decodeIfPresent(Guest.self, forKey: .guest)
    }

    /// Reads the file at `url` and resolves its paths against the file's directory.
    static func load(from url: URL) throws -> BundleConfiguration {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ValidationError("cannot read \(url.path): \(error.localizedDescription)")
        }
        var configuration: BundleConfiguration
        do {
            configuration = try TOMLDecoder().decode(BundleConfiguration.self, from: text)
        } catch {
            throw ValidationError("\(url.path) is not a valid bundle configuration: \(error)")
        }
        let directory = url.deletingLastPathComponent()
        configuration.bundle = configuration.bundle.map { resolve($0, against: directory) }
        if let image = configuration.restoreImage, !image.lowercased().hasPrefix("http://"), !image.lowercased().hasPrefix("https://") {
            configuration.restoreImage = resolve(image, against: directory)
        }
        let authorizedKeys = configuration.account?.authorizedKeys?.map { resolve($0, against: directory) }
        configuration.account?.authorizedKeys = authorizedKeys
        let scripts = configuration.guest?.scripts?.map { resolve($0, against: directory) }
        configuration.guest?.scripts = scripts
        return configuration
    }

    static func resolve(_ path: String, against directory: URL) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : directory.appendingPathComponent(expanded).standardizedFileURL.path
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Throws when the table being decoded holds a key that is not in `known`.
private func refuseUnknownKeys<Key: CodingKey>(in decoder: any Decoder, known: [Key]) throws {
    let names = Set(known.map(\.stringValue))
    let unknown = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue).filter { !names.contains($0) }.sorted()
    guard unknown.isEmpty else {
        let path = decoder.codingPath.map(\.stringValue).joined(separator: ".")
        throw ValidationError("unknown key\(unknown.count == 1 ? "" : "s") \(unknown.joined(separator: ", "))\(path.isEmpty ? "" : " in [\(path)]")")
    }
}
