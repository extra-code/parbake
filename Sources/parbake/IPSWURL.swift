// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Virtualization

extension ParbakeTool {
    struct IPSWURL: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ipsw-url",
            abstract: "Print the download URL of the latest restore image this host supports"
        )

        func run() async throws {
            let image = try await VZMacOSRestoreImage.latestSupported
            print(image.url.absoluteString)
        }
    }
}
