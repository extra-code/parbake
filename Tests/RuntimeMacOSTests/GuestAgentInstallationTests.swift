// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import RuntimeMacOS

struct GuestAgentInstallationTests {
    /// Runs `tool arguments` with `input` on standard input and returns its exit status.
    private func status(of tool: String, _ arguments: [String], input: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test
    func testTheInstallationScriptAndItsRootCommandsParse() throws {
        #expect(try status(of: "/bin/bash", ["-n"], input: try GuestAgentInstallation.script(password: "pa$$ 'word")) == 0)
        #expect(try status(of: "/bin/sh", ["-n"], input: GuestAgentInstallation.rootCommands) == 0)
    }

    @Test
    func testThePropertyListIsValid() throws {
        #expect(try status(of: "/usr/bin/plutil", ["-lint", "-s", "-"], input: GuestAgentInstallation.propertyList) == 0)
    }

    @Test
    func testThePreparationInstallsTheAgentAndLeavesTheShutdownToTheHost() throws {
        let script = try GuestPreparation.script(username: "ci", password: "x", publicKeys: ["k"], tidy: false, installAgent: true)
        #expect(try status(of: "/bin/bash", ["-n"], input: script) == 0)
        #expect(script.contains("launchctl bootstrap system \(GuestAgentInstallation.propertyListPath)"))
        #expect(!script.contains("sudo -n /sbin/shutdown -h now"))
        let lines = script.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.last == "echo '\(GuestPreparation.preparedMarker)'")
    }
}

struct GeneratedScriptGoldenTests {
    @Test
    func testThePreparationScriptIsByteStable() throws {
        let script = try GuestPreparation.script(username: "ci", password: "pw", publicKeys: ["k1"], tidy: false)
        #expect(script == Self.preparation)
    }

    @Test
    func testThePreparationScriptWithTheAgentAndTidyingIsByteStable() throws {
        let script = try GuestPreparation.script(
            username: "ci", password: "pw", publicKeys: ["k1", "k2"], tidy: true, installAgent: true, sudoCommands: ["/usr/bin/true"])
        #expect(script == Self.preparationWithAgent)
    }

    @Test
    func testTheInstallationScriptIsByteStable() throws {
        #expect(try GuestAgentInstallation.script(password: "pw") == Self.installation)
    }

    private static let preparation = #"""
        set -eu
        umask 077
        mkdir -p "$HOME/.ssh"
        cat >> "$HOME/.ssh/authorized_keys" <<'PARBAKE_KEYS'
        k1
        PARBAKE_KEYS
        IFS= read -r PARBAKE_PASSWORD <<'PARBAKE_PASSWORD'
        pw
        PARBAKE_PASSWORD
        PARBAKE_ROOT=$(cat <<'PARBAKE_ROOT'
        set -eu
        printf '%s ALL=(root) NOPASSWD: %s\n' 'ci' '/sbin/shutdown' > /etc/sudoers.d/parbake.new
        chmod 0440 /etc/sudoers.d/parbake.new
        visudo -cqf /etc/sudoers.d/parbake.new
        mv /etc/sudoers.d/parbake.new /etc/sudoers.d/parbake
        PARBAKE_ROOT
        )
        printf '%s\n' "$PARBAKE_PASSWORD" | sudo -S -p '' /bin/sh -c "$PARBAKE_ROOT"
        unset PARBAKE_PASSWORD
        sudo -n -l /sbin/shutdown >/dev/null
        echo 'parbake: prepared'
        sudo -n /sbin/shutdown -h now >/dev/null

        """#

    private static let preparationWithAgent = #"""
        set -eu
        umask 077
        mkdir -p "$HOME/.ssh"
        cat >> "$HOME/.ssh/authorized_keys" <<'PARBAKE_KEYS'
        k1
        k2
        PARBAKE_KEYS
        rm -rf "$HOME"/Library/Caches/* 2>/dev/null || true
        IFS= read -r PARBAKE_PASSWORD <<'PARBAKE_PASSWORD'
        pw
        PARBAKE_PASSWORD
        PARBAKE_ROOT=$(cat <<'PARBAKE_ROOT'
        set -eu
        printf '%s ALL=(root) NOPASSWD: %s\n' 'ci' '/sbin/shutdown, /usr/bin/true' > /etc/sudoers.d/parbake.new
        chmod 0440 /etc/sudoers.d/parbake.new
        visudo -cqf /etc/sudoers.d/parbake.new
        mv /etc/sudoers.d/parbake.new /etc/sudoers.d/parbake
        mdutil -a -i off >/dev/null
        mdutil -a -E >/dev/null 2>&1 || true
        rm -rf /Library/Caches/* 2>/dev/null || true
        install -d -m 0755 -o root -g wheel /usr/local/libexec
        install -m 0755 -o root -g wheel /tmp/parbake-agent.staged /usr/local/libexec/parbake-agent
        rm -f /tmp/parbake-agent.staged
        cat > /Library/LaunchDaemons/container-runtime-macos.agent.plist.new <<'PARBAKE_PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>container-runtime-macos.agent</string>
          <key>ProgramArguments</key><array><string>/usr/local/libexec/parbake-agent</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>StandardErrorPath</key><string>/var/log/parbake-agent.log</string>
        </dict>
        </plist>
        PARBAKE_PLIST
        chown root:wheel /Library/LaunchDaemons/container-runtime-macos.agent.plist.new
        chmod 0644 /Library/LaunchDaemons/container-runtime-macos.agent.plist.new
        plutil -lint -s /Library/LaunchDaemons/container-runtime-macos.agent.plist.new
        mv /Library/LaunchDaemons/container-runtime-macos.agent.plist.new /Library/LaunchDaemons/container-runtime-macos.agent.plist
        launchctl bootout system/container-runtime-macos.agent 2>/dev/null || true
        for attempt in 1 2 3 4 5; do
            if launchctl bootstrap system /Library/LaunchDaemons/container-runtime-macos.agent.plist; then break; fi
            if [ "$attempt" = 5 ]; then exit 1; fi
            sleep 2
            launchctl bootout system/container-runtime-macos.agent 2>/dev/null || true
        done
        PARBAKE_ROOT
        )
        printf '%s\n' "$PARBAKE_PASSWORD" | sudo -S -p '' /bin/sh -c "$PARBAKE_ROOT"
        unset PARBAKE_PASSWORD
        sudo -n -l /sbin/shutdown >/dev/null
        echo 'parbake: prepared'

        """#

    private static let installation = #"""
        set -eu
        IFS= read -r PARBAKE_PASSWORD <<'PARBAKE_PASSWORD'
        pw
        PARBAKE_PASSWORD
        PARBAKE_ROOT=$(cat <<'PARBAKE_ROOT'
        set -eu
        install -d -m 0755 -o root -g wheel /usr/local/libexec
        install -m 0755 -o root -g wheel /tmp/parbake-agent.staged /usr/local/libexec/parbake-agent
        rm -f /tmp/parbake-agent.staged
        cat > /Library/LaunchDaemons/container-runtime-macos.agent.plist.new <<'PARBAKE_PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>container-runtime-macos.agent</string>
          <key>ProgramArguments</key><array><string>/usr/local/libexec/parbake-agent</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>StandardErrorPath</key><string>/var/log/parbake-agent.log</string>
        </dict>
        </plist>
        PARBAKE_PLIST
        chown root:wheel /Library/LaunchDaemons/container-runtime-macos.agent.plist.new
        chmod 0644 /Library/LaunchDaemons/container-runtime-macos.agent.plist.new
        plutil -lint -s /Library/LaunchDaemons/container-runtime-macos.agent.plist.new
        mv /Library/LaunchDaemons/container-runtime-macos.agent.plist.new /Library/LaunchDaemons/container-runtime-macos.agent.plist
        launchctl bootout system/container-runtime-macos.agent 2>/dev/null || true
        for attempt in 1 2 3 4 5; do
            if launchctl bootstrap system /Library/LaunchDaemons/container-runtime-macos.agent.plist; then break; fi
            if [ "$attempt" = 5 ]; then exit 1; fi
            sleep 2
            launchctl bootout system/container-runtime-macos.agent 2>/dev/null || true
        done
        PARBAKE_ROOT
        )
        printf '%s\n' "$PARBAKE_PASSWORD" | sudo -S -p '' /bin/sh -c "$PARBAKE_ROOT"
        unset PARBAKE_PASSWORD
        echo 'parbake: agent installed'

        """#
}
