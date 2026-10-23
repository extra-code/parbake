// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

public enum Parbake {
    /// The release of this build; both CLIs and the agent report it. `scripts/release.sh` stamps the marked line.
    public static let release = "0.0.0-dev"  // STAMP:release
}

/// The agent's version line: `<protocol>` followed by optional informational fields.
public struct AgentVersionLine: Equatable, Sendable, CustomStringConvertible {
    /// The wire protocol; it changes only when the guest agent's wire contract changes.
    public static let protocolVersion = 1
    /// The agent environment variable whose value is the version line.
    public static let variable = "CONTAINER_RUNTIME_MACOS_AGENT"
    /// The line this build's agent sends: `"\(protocolVersion) \(Parbake.release)"`.
    public static let current = AgentVersionLine(protocolNumber: protocolVersion, release: Parbake.release)

    public let protocolNumber: Int
    /// The second field, or nil when the line has none or it is not a valid release.
    public let release: String?

    public init(protocolNumber: Int, release: String?) {
        self.protocolNumber = protocolNumber
        self.release = release
    }

    /// Parses a line; nil when the first field is not a decimal integer.
    public init?(_ line: String) {
        let trimmed = line.trimmingWhitespace()
        let fields = trimmed.split(separator: " ", omittingEmptySubsequences: false)
        guard let first = fields.first, !first.isEmpty, first.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
            let number = Int(first)
        else { return nil }
        self.protocolNumber = number
        if fields.count > 1, Self.isValidRelease(fields[1]) {
            self.release = String(fields[1])
        } else {
            self.release = nil
        }
    }

    /// `"<protocol> <release>"`, or `"<protocol>"` without a release.
    public var description: String {
        guard let release else { return "\(protocolNumber)" }
        return "\(protocolNumber) \(release)"
    }

    private static func isValidRelease(_ field: Substring) -> Bool {
        let bytes = field.utf8
        guard (1...32).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x2D || byte == 0x2B
        }
    }
}

extension String {
    fileprivate func trimmingWhitespace() -> String {
        let whitespace: Set<Character> = [" ", "\t", "\n", "\r"]
        var scalars = Substring(self)
        while let first = scalars.first, whitespace.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, whitespace.contains(last) { scalars.removeLast() }
        return String(scalars)
    }
}
