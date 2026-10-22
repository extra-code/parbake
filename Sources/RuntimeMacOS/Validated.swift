// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Darwin

/// A guest account name that is safe to put in a shell script and an ssh argument list.
public struct GuestUsername: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard (1...31).contains(bytes.count) else { return nil }
        let first = bytes[0]
        guard (first >= 0x61 && first <= 0x7A) || first == 0x5F else { return nil }
        for byte in bytes.dropFirst() {
            let ok = (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F || byte == 0x2D
            guard ok else { return nil }
        }
        self.rawValue = rawValue
    }

    public static let rule = "1 to 31 characters: a lowercase letter or _ first, then a-z, 0-9, _ or -"
}

/// An absolute command path that may appear in a sudoers rule.
public struct SudoCommand: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard bytes.count >= 2, bytes[0] == 0x2F else { return nil }
        for byte in bytes {
            let ok =
                (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2E || byte == 0x5F || byte == 0x2F || byte == 0x2B || byte == 0x2D
            guard ok else { return nil }
        }
        self.rawValue = rawValue
    }
}

public enum ScriptInput {
    /// Throws ContainerizationError(.invalidArgument) naming `field` when `value` holds a control
    /// character (U+0000-U+001F, U+007F) or the text "PARBAKE_".
    public static func check(_ value: String, field: String) throws {
        if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw ContainerizationError(.invalidArgument, message: "\(field) must not contain control characters")
        }
        if value.contains("PARBAKE_") {
            throw ContainerizationError(.invalidArgument, message: "\(field) must not contain the text PARBAKE_")
        }
    }
}

public enum IPv4Address {
    /// A dotted quad that `inet_pton(AF_INET)` accepts, with no surrounding space.
    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }) else { return false }
        var address = in_addr()
        return inet_pton(AF_INET, value, &address) == 1
    }
}
