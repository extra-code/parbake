// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

@Suite(.timeLimit(.minutes(1)))
struct HostProcessConcurrencyTests {
    /// Four runs per core at once, each held until its timeout, finish without exhausting the cooperative pool.
    @Test
    func testMoreConcurrentRunsThanPoolThreadsAllFinish() async throws {
        let width = ProcessInfo.processInfo.activeProcessorCount * 4
        try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
            for _ in 0..<width {
                group.addTask {
                    try await HostProcess.run(
                        URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec sleep 30"], input: Data("x".utf8),
                        timeout: .milliseconds(300))
                }
            }
            var finished = 0
            for try await result in group {
                #expect(result.timedOut)
                #expect(result.status == 128 + SIGTERM)
                finished += 1
            }
            #expect(finished == width)
        }
    }
}
