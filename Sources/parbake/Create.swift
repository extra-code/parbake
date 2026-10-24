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

                --config reads the bundle from a TOML file: bundle, restore-image, disk-size, cpus and \
                memory at the top, [account] with username, full-name, authorized-keys, keychain and \
                keychain-service, and [guest] with tidy, agent, sudo (commands allowed without a \
                password) and scripts (run as root through the agent after provisioning). Options on \
                the command line take precedence over the file.
                """
        )

        @Option(name: .long, help: "TOML file that describes the bundle")
        var config: String?

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

        @Option(name: .long, help: "Size of the sparse disk image in GiB (default: 100)")
        var diskSize: UInt64?

        @Option(name: .long, help: "Number of CPUs for installation and first boot (default: 4)")
        var cpus: Int?

        @Option(name: .long, help: "Memory in GiB for installation and first boot (default: 8)")
        var memory: UInt64?

        @Option(name: .long, help: "Create this account on the first boot instead of opening the Setup Assistant")
        var username: String?

        @Option(name: .long, help: "Full name of that account (default: the username)")
        var fullName: String?

        @Option(name: .long, help: "Public key file to add to that account's authorized_keys; repeatable")
        var authorizedKey: [String] = []

        @Option(name: .long, help: "Command that account may run with sudo without a password; repeatable")
        var sudo: [String] = []

        @Option(name: .long, help: "Shell script to run as root through the agent after provisioning; repeatable")
        var script: [String] = []

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

        /// The password read from standard input before the download; not a command-line value.
        var stdinPassword: String?

        func run() async throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            var resolved = self
            if let config {
                try resolved.apply(BundleConfiguration.load(from: URL(fileURLWithPath: config)))
            }
            try resolved.validateScripts()
            try await resolved.validateAccount()
            try resolved.validateRestoreImage()
            resolved.stdinPassword = try resolved.readStdinPassword()
            try await resolved.create()
        }

        /// Takes every value the command line left open from `configuration`. Flags that are off on
        /// the command line take the file's value; lists from the command line replace the file's.
        mutating func apply(_ configuration: BundleConfiguration) {
            bundle = bundle ?? configuration.bundle
            restoreImage = restoreImage ?? configuration.restoreImage
            diskSize = diskSize ?? configuration.diskSize
            cpus = cpus ?? configuration.cpus
            memory = memory ?? configuration.memory
            if let account = configuration.account {
                username = username ?? account.username
                fullName = fullName ?? account.fullName
                authorizedKey = authorizedKey.isEmpty ? account.authorizedKeys ?? [] : authorizedKey
                keychain = keychain || account.keychain == true
                if keychainService == GuestCredentials.defaultService, let service = account.keychainService {
                    keychainService = service
                }
            }
            if let guest = configuration.guest {
                tidy = tidy || guest.tidy == true
                noAgent = noAgent || guest.agent == false
                sudo = sudo.isEmpty ? guest.sudo ?? [] : sudo
                script = script.isEmpty ? guest.scripts ?? [] : script
            }
        }

        /// Scripts run through the agent of the provisioned account, so they need both.
        func validateScripts() throws {
            guard !script.isEmpty else {
                return
            }
            guard username != nil, !noAgent else {
                throw ValidationError("scripts run through the guest agent after provisioning; they need --username and the agent")
            }
        }

        /// A restore image given as a path must exist before the lock and the download.
        func validateRestoreImage() throws {
            guard let restoreImage, case .file(let file) = try RestoreImageSource(restoreImage) else { return }
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw RuntimeFailure.restoreImageMissing(path: file.path)
            }
        }

        /// The account password from standard input when it is piped, read before the download so
        /// that a missing password fails early. A terminal is prompted later; the keychain has its own path.
        func readStdinPassword(
            isTerminal: Bool = isatty(STDIN_FILENO) != 0,
            read: () throws -> String = {
                try AgentSetup.promptedPassword(for: "")
            }
        ) throws -> String? {
            guard username != nil, !keychain, !isTerminal else { return nil }
            return try read()
        }

        /// Checks the account inputs before anything is downloaded.
        func validateAccount() async throws {
            guard let username else {
                try ProvisionInputs.checkAccountFlags(
                    username: nil, authorizedKeys: authorizedKey, sudo: sudo, keychain: keychain, fullName: fullName, tidy: tidy)
                return
            }
            try await ProvisionInputs.validate(
                username: username, authorizedKeys: authorizedKey.map { URL(fileURLWithPath: $0) }, sudo: sudo, agent: agent,
                noAgent: noAgent, scripts: script.map { URL(fileURLWithPath: $0) }, keychain: keychain, keychainService: keychainService)
        }

        private func create() async throws {
            let home = ParbakeHome()
            let target = URL(fileURLWithPath: bundle ?? home.defaultBundle.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lock = try FileLock.acquire(
                target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".parbake-lock"), wait: false,
                holder: "parbake create")
            defer { lock.release() }
            let replacing = replace && FileManager.default.fileExists(atPath: target.path)
            guard replace || !FileManager.default.fileExists(atPath: target.path) else {
                throw ValidationError("\(target.path) already exists; pass --replace to rebuild it")
            }
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
                "--bundle", path.path, "--restore-image", image.path, "--disk-size", "\(diskSize ?? 100)", "--cpus", "\(cpus ?? 4)",
                "--memory", "\(memory ?? 8)",
            ])
            try await install.run()

            if let username {
                print("==> Provisioning the account \(username) on the first boot")
                var arguments = ["--bundle", path.path, "--username", username, "--cpus", "\(cpus ?? 4)", "--memory", "\(memory ?? 8)"]
                arguments += fullName.map { ["--full-name", $0] } ?? []
                arguments += authorizedKey.flatMap { ["--authorized-key", $0] }
                arguments += sudo.flatMap { ["--sudo", $0] }
                arguments += keychain ? ["--keychain", "--keychain-service", keychainService] : []
                arguments += tidy ? ["--tidy"] : []
                arguments += agent.map { ["--agent", $0] } ?? []
                arguments += noAgent ? ["--no-agent"] : []
                var provision = try Provision.parse(arguments)
                provision.password = stdinPassword
                try await provision.run()
                if !script.isEmpty {
                    print("==> Running \(script.count) script(s) in the guest")
                    try await GuestScript.run(
                        script.map { URL(fileURLWithPath: $0) }, in: try MacOSVMBundle(url: path), cpus: cpus ?? 4, memory: memory ?? 8, timeout: 300)
                }
            } else if !noSetup {
                print(
                    """
                    ==> Opening the guest for the Setup Assistant
                    In the window:
                      1. Complete the Setup Assistant and create the user account.
                      2. Optional: System Settings > General > Sharing > Remote Login, for SSH access.
                      3. Shut down the guest from its Apple menu; the window closes and parbake continues.
                    """)
                let setup = try Setup.parse(["--bundle", path.path, "--cpus", "\(cpus ?? 4)", "--memory", "\(memory ?? 8)"])
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
            throw ParbakeError.runtime(
                "rebuilding \(target.path) needs \(format.string(fromByteCount: needed)) beside it, "
                    + "the size of the existing bundle; \(format.string(fromByteCount: available)) is free")
        }
    }
}
