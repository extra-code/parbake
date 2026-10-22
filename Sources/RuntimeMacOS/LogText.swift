// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Text from the guest, made safe to write to a log or a terminal.
public enum LogText {
    /// The longest guest text, in UTF-8 bytes, that `sanitized` keeps.
    public static let maximumBytes = 512

    /// `text` with leading and trailing whitespace removed, every control character escaped as
    /// `\n`, `\r`, `\t` or `\u{XX}`, and at most `maximumBytes` bytes kept; a longer text ends in
    /// `…[truncated]`.
    public static func sanitized(_ text: String) -> String {
        var result = ""
        var bytes = 0
        var truncated = false
        for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            let piece: String
            switch scalar {
            case "\n": piece = "\\n"
            case "\r": piece = "\\r"
            case "\t": piece = "\\t"
            case _ where scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value):
                let hex = String(scalar.value, radix: 16, uppercase: true)
                piece = "\\u{" + String(repeating: "0", count: max(0, 2 - hex.count)) + hex + "}"
            default: piece = String(scalar)
            }
            guard bytes + piece.utf8.count <= maximumBytes else {
                truncated = true
                break
            }
            result += piece
            bytes += piece.utf8.count
        }
        return truncated ? result + "…[truncated]" : result
    }
}
