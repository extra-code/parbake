// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import RuntimeMacOS
import Virtualization

extension ParbakeTool {
    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a VM bundle: download a restore image, install macOS, and provision or set up the guest",
            discussion: """
                Downloads the latest restore image this host supports into the cache, resuming an \
                interrupted download and reusing a finished one, installs macOS into a new bundle, and \
                then either provisions an account (--username, see `parbake provision`) or opens the \
                guest in a window for the Setup Assistant.

                PARBAKE_HOME moves the default bundle and the cache to another directory, for example \
                on an external SSD: the bundle defaults to $PARBAKE_HOME/VM.bundle and the cache to \
                $PARBAKE_HOME/cache.
                """
        )

        @Option(name: .long, help: "Bundle to create (default: $PARBAKE_HOME/VM.bundle, else ~/VM.bundle)")
        var bundle: String?

        @Option(name: .long, help: "Restore image to install; skips the download")
        var ipsw: String?

        @Option(name: .long, help: "Download directory for restore images (default: $PARBAKE_HOME/cache, else ~/Library/Caches/parbake)")
        var cacheDir: String?

        @Option(name: .long, help: "Size of the sparse disk image in GiB")
        var diskSize: UInt64 = 100

        @Option(name: .long, help: "Number of CPUs for installation and first boot")
        var cpus: Int = 4

        @Option(name: .long, help: "Memory in GiB for installation and first boot")
        var memory: UInt64 = 8

        @Option(name: .long, help: "Create this account on the first boot instead of opening the Setup Assistant")
        var username: String?

        @Option(name: .long, help: "Full name of that account (default: the username)")
        var fullName: String?

        @Option(name: .long, help: "Public key file to add to that account's authorized_keys")
        var authorizedKey: String?

        @Flag(name: .long, help: "Take that account's password from the login keychain, generating one when it has none")
        var keychain = false

        @Option(name: .long, help: "Keychain service of the stored password")
        var keychainService = GuestCredentials.defaultService

        @Flag(name: .long, help: "Turn Spotlight indexing off and empty the caches before the shutdown")
        var tidy = false

        @Option(name: .long, help: "Agent executable to install in the guest (default: next to parbake)")
        var agent: String?

        @Flag(name: .long, help: "Do not install the guest agent")
        var noAgent = false

        @Flag(name: .long, help: "Without --username, skip the Setup Assistant window")
        var noSetup = false

        func run() async throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            let home = ParbakeHome()
            let bundlePath = bundle ?? home.defaultBundle.path
            guard !FileManager.default.fileExists(atPath: bundlePath) else {
                throw ValidationError("\(bundlePath) already exists; remove it or pass --bundle")
            }
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: bundlePath).deletingLastPathComponent(), withIntermediateDirectories: true)

            let restoreImage: String
            if let ipsw {
                restoreImage = ipsw
            } else {
                restoreImage = try await RestoreImageCache(directory: cacheDir.map { URL(fileURLWithPath: $0) } ?? home.cache).latest().path
            }

            print("==> Installing macOS into \(bundlePath)")
            let install = try Install.parse([
                "--bundle", bundlePath, "--ipsw", restoreImage, "--disk-size", "\(diskSize)", "--cpus", "\(cpus)", "--memory", "\(memory)",
            ])
            try await install.run()

            if let username {
                print("==> Provisioning the account \(username) on the first boot")
                var arguments = ["--bundle", bundlePath, "--username", username, "--cpus", "\(cpus)", "--memory", "\(memory)"]
                arguments += fullName.map { ["--full-name", $0] } ?? []
                arguments += authorizedKey.map { ["--authorized-key", $0] } ?? []
                arguments += keychain ? ["--keychain", "--keychain-service", keychainService] : []
                arguments += tidy ? ["--tidy"] : []
                arguments += agent.map { ["--agent", $0] } ?? []
                arguments += noAgent ? ["--no-agent"] : []
                let provision = try Provision.parse(arguments)
                try await provision.run()
            } else if !noSetup {
                print(
                    """
                    ==> Opening the guest for the Setup Assistant
                    In the window:
                      1. Complete the Setup Assistant and create the user account.
                      2. Optional: System Settings > General > Sharing > Remote Login, for SSH access.
                      3. Shut down the guest from its Apple menu; the window closes and parbake continues.
                    """)
                let setup = try Setup.parse(["--bundle", bundlePath, "--cpus", "\(cpus)", "--memory", "\(memory)"])
                try await setup.run()
            }

            print("==> Created \(bundlePath)")
            print("Run a container from it with --label runtime-macos.bundle=\(bundlePath)")
        }
    }
}

/// Restore images downloaded once and reused; a `.done` file next to an image marks it complete.
struct RestoreImageCache {
    let directory: URL

    /// Returns the latest restore image this host supports, downloading it first unless the cache
    /// holds it complete; an interrupted download resumes.
    func latest() async throws -> URL {
        let url = try await VZMacOSRestoreImage.latestSupported.url
        let image = directory.appendingPathComponent(url.lastPathComponent)
        let done = image.appendingPathExtension("done")
        if FileManager.default.fileExists(atPath: done.path) {
            print("==> Using cached \(image.path)")
            return image
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("==> Downloading \(url.lastPathComponent) (resumes an interrupted download)")
        // curl resumes from the partial file and shows progress; URLSession keeps no resume data across runs.
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["--fail", "--location", "--continue-at", "-", "--output", image.path, url.absoluteString]
        try curl.run()
        curl.waitUntilExit()
        guard curl.terminationStatus == 0 else {
            throw ValidationError("downloading \(url.absoluteString) failed (curl exit status \(curl.terminationStatus)); run create again to resume")
        }
        FileManager.default.createFile(atPath: done.path, contents: nil)
        return image
    }
}
