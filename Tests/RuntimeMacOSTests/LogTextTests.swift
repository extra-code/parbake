// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RuntimeMacOS

struct LogTextTests {
    @Test
    func testPlainTextPassesThroughTrimmed() {
        #expect(LogText.sanitized("  Permission denied (publickey).\n") == "Permission denied (publickey).")
    }

    @Test(arguments: [
        ("a\nb", "a\\nb"), ("a\rb", "a\\rb"), ("a\tb", "a\\tb"),
        ("a\u{1B}[31mb", "a\\u{1B}[31mb"), ("a\u{0}b", "a\\u{00}b"), ("a\u{7F}b", "a\\u{7F}b"),
    ])
    func testControlCharactersAreEscaped(input: String, expected: String) {
        #expect(LogText.sanitized(input) == expected)
    }

    @Test
    func testLongTextIsCappedWithAMarker() {
        let result = LogText.sanitized(String(repeating: "x", count: 5000))
        #expect(result == String(repeating: "x", count: LogText.maximumBytes) + "…[truncated]")
    }

    @Test
    func testTextAtTheCapIsKept() {
        let text = String(repeating: "x", count: LogText.maximumBytes)
        #expect(LogText.sanitized(text) == text)
    }

    @Test
    func testTheCapNeverSplitsAMultiByteCharacter() {
        let result = LogText.sanitized(String(repeating: "é", count: 400))
        #expect(result.hasSuffix("…[truncated]"))
        #expect(result.dropLast("…[truncated]".count).utf8.count <= LogText.maximumBytes)
    }

    @Test
    func testEscapesCountTowardsTheCap() {
        let result = LogText.sanitized(String(repeating: "a\n", count: 400))
        #expect(result.hasPrefix("a\\na\\n"))
        #expect(result.hasSuffix("…[truncated]"))
    }
}
