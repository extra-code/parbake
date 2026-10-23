// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RuntimeMacOS
import Testing

@testable import parbake

struct BundleConfigurationTests {
    private func write(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parbake-config-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("parbake.toml")
        try Data(text.utf8).write(to: file)
        return file
    }

    private let example = """
        bundle = "bundles/VM.bundle"
        restore-image = "https://mirror.example/UniversalMac_27.0.1_26A434_Restore.ipsw"
        disk-size = 120
        cpus = 6
        memory = 12

        [account]
        username = "runner"
        full-name = "CI Runner"
        authorized-keys = ["keys/ci.pub", "/etc/ci/admin.pub"]
        keychain = true

        [guest]
        tidy = true
        sudo = ["/usr/sbin/softwareupdate"]
        scripts = ["setup/brew.sh"]
        """

    @Test
    func testAFullFileIsReadWithPathsRelativeToIt() throws {
        let file = try write(example)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let directory = file.deletingLastPathComponent().standardizedFileURL.path

        let configuration = try BundleConfiguration.load(from: file)

        #expect(configuration.bundle == directory + "/bundles/VM.bundle")
        #expect(configuration.restoreImage == "https://mirror.example/UniversalMac_27.0.1_26A434_Restore.ipsw")
        #expect(configuration.diskSize == 120)
        #expect(configuration.account?.username == "runner")
        #expect(configuration.account?.authorizedKeys == [directory + "/keys/ci.pub", "/etc/ci/admin.pub"])
        #expect(configuration.guest?.sudo == ["/usr/sbin/softwareupdate"])
        #expect(configuration.guest?.scripts == [directory + "/setup/brew.sh"])
    }

    @Test(arguments: [
        ("disksize = 10", "disksize"),
        ("[account]\nusername = \"runner\"\nfullname = \"x\"", "fullname in [account]"),
        ("[guest]\nscript = [\"a.sh\"]", "script in [guest]"),
    ])
    func testAnUnknownKeyIsRefused(text: String, named: String) throws {
        let file = try write(text)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        #expect {
            try BundleConfiguration.load(from: file)
        } throws: { error in
            "\(error)".contains("unknown key \(named)")
        }
    }

    @Test
    func testTheCommandLineTakesPrecedenceOverTheFile() throws {
        let file = try write(example)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var create = try ParbakeTool.Create.parse(["--cpus", "2", "--username", "builder", "--sudo", "/usr/bin/true"])

        create.apply(try BundleConfiguration.load(from: file))

        #expect(create.cpus == 2)
        #expect(create.memory == 12)
        #expect(create.username == "builder")
        #expect(create.fullName == "CI Runner")
        #expect(create.sudo == ["/usr/bin/true"])
        #expect(create.keychain)
        #expect(create.tidy)
        #expect(create.script.count == 1)
    }

    @Test
    func testScriptsNeedAnAccountAndTheAgent() throws {
        let create = try ParbakeTool.Create.parse(["--script", "a.sh", "--username", "runner", "--no-agent"])

        #expect(throws: (any Error).self) { try create.validateScripts() }
    }

    @Test(arguments: ["usr/bin/true", "/bin/a, /bin/b", "/bin/sh -c 'x'", "/bin/a\n/bin/b"])
    func testASudoCommandThatWouldBreakTheEntryIsRefused(command: String) {
        #expect(throws: (any Error).self) { try GuestPreparation.checkSudoCommand(command) }
    }

    @Test
    func testSudoCommandsJoinTheSudoersEntry() throws {
        try GuestPreparation.checkSudoCommand("/usr/sbin/softwareupdate")
        #expect(throws: (any Error).self) { try GuestPreparation.checkSudoCommand("/usr/sbin/softwareupdate -i *") }
        let script = try GuestPreparation.script(
            username: "runner", password: "pw", publicKeys: ["ssh-ed25519 AAAA"], tidy: false, sudoCommands: ["/usr/sbin/softwareupdate"])

        #expect(script.contains("'/sbin/shutdown, /usr/sbin/softwareupdate'"))
    }
}
