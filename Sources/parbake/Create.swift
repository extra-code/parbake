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
                Downloads the restore image into the cache, resuming an interrupted download and \
                reusing a finished one, installs macOS into a new bundle, and then either provisions an \
                account (--username, see `parbake provision`) or opens the guest in a window for the \
                Setup Assistant. Without --restore-image, the image is the latest one this host supports. \
                After a successful download, the cache keeps only the image just used.

                --replace rebuilds an existing bundle: the new one is built next to it and takes its \
                place only once it is complete, so a failed build leaves the existing bundle as it was.

                PARBAKE_HOME moves the default bundle and the cache to another directory, for example \
                on an external SSD: the bundle defaults to $PARBAKE_HOME/VM.bundle and the cache to \
                $PARBAKE_HOME/cache.
                """
        )

        @Option(name: .long, help: "Bundle to create (default: $PARBAKE_HOME/VM.bundle, else ~/VM.bundle)")
        var bundle: String?

        @Option(name: .long, help: "Restore image to install: a path, or an http(s) URL to download into the cache (default: the latest image this host supports)")
        var restoreImage: String?

        @Flag(name: .long, help: "Replace an existing bundle once the new one is complete")
        var replace = false

        @Flag(name: .long, help: "Keep older restore images in the cache")
        var keepCache = false

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
            let target = URL(fileURLWithPath: bundle ?? home.defaultBundle.path)
            let replacing = replace && FileManager.default.fileExists(atPath: target.path)
            guard replace || !FileManager.default.fileExists(atPath: target.path) else {
                throw ValidationError("\(target.path) already exists; pass --replace to rebuild it")
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if replacing {
                try checkFreeSpace(toReplace: target)
                print(
                    """
                    ==> Rebuilding \(target.path)
                    Containers made from it will not stack on the new disk image; their start fails unless they
                    carry --label runtime-macos.on-incompatible-overlay=discard, which starts them over.
                    """)
            }

            let cache = RestoreImageCache(directory: cacheDir.map { URL(fileURLWithPath: $0) } ?? home.cache)
            let source: RestoreImageSource
            if let restoreImage {
                source = try RestoreImageSource(restoreImage)
            } else {
                source = .url(try await VZMacOSRestoreImage.latestSupported.url)
            }
            let image: URL
            switch source {
            case .file(let file):
                image = file
            case .url(let url):
                if cache.isComplete(cache.file(for: url)) {
                    print("==> Using cached \(cache.file(for: url).path)")
                } else {
                    print("==> Downloading \(url.lastPathComponent) (resumes an interrupted download)")
                }
                image = try await cache.fetch(url)
            }

            try await BundleReplacement.build(at: target, replacing: replacing) { path in
                try await build(at: path, from: image)
            }

            if case .url = source, !keepCache {
                for removed in try cache.prune(keeping: image) {
                    print("==> Removed \(removed.lastPathComponent) from the cache")
                }
            }
            print("==> Created \(target.path)")
            print("Run a container from it with --label runtime-macos.bundle=\(target.path)")
        }

        private func build(at path: URL, from image: URL) async throws {
            print("==> Installing macOS into \(path.path)")
            let install = try Install.parse([
                "--bundle", path.path, "--restore-image", image.path, "--disk-size", "\(diskSize)", "--cpus", "\(cpus)", "--memory", "\(memory)",
            ])
            try await install.run()

            if let username {
                print("==> Provisioning the account \(username) on the first boot")
                var arguments = ["--bundle", path.path, "--username", username, "--cpus", "\(cpus)", "--memory", "\(memory)"]
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
                let setup = try Setup.parse(["--bundle", path.path, "--cpus", "\(cpus)", "--memory", "\(memory)"])
                try await setup.run()
            }
        }

        /// The new bundle is built next to the existing one, so the volume must hold a second copy.
        private func checkFreeSpace(toReplace target: URL) throws {
            let needed = BundleReplacement.allocatedSize(of: target)
            guard let available = BundleReplacement.availableCapacity(at: target.deletingLastPathComponent()), available < needed else {
                return
            }
            let format = ByteCountFormatter()
            throw ValidationError(
                "rebuilding \(target.path) needs \(format.string(fromByteCount: needed)) beside it, "
                    + "the size of the existing bundle; \(format.string(fromByteCount: available)) is free")
        }
    }
}
