// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How the guest agent is installed in a guest: as a LaunchDaemon that runs as root, so it can start
/// processes as any account and shut the guest down.
public enum GuestAgentInstallation {
    public static let label = "container-runtime-macos.agent"
    public static let programPath = "/usr/local/libexec/parbake-agent"
    public static let propertyListPath = "/Library/LaunchDaemons/\(label).plist"
    public static let logPath = "/var/log/parbake-agent.log"
    /// Where the account leaves the agent binary for the root part of the installation.
    public static let stagedPath = "/tmp/parbake-agent.staged"
    /// The line the installation script prints once launchd runs the agent.
    public static let installedMarker = "parbake: agent installed"

    /// How long the agent gets to answer over vsock after the installation.
    public static let readinessTimeout: Duration = .seconds(120)

    public static let propertyList = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(programPath)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>StandardErrorPath</key><string>\(logPath)</string>
        </dict>
        </plist>
        """

    /// Shell commands, run as root, that install the staged binary and the property list and
    /// (re)start the daemon. The bootstrap retries because launchd can still hold the old daemon
    /// right after a boot, and then refuses it with an input/output error.
    public static let rootCommands = """
        install -d -m 0755 -o root -g wheel /usr/local/libexec
        install -m 0755 -o root -g wheel \(stagedPath) \(programPath)
        rm -f \(stagedPath)
        cat > \(propertyListPath).new <<'PARBAKE_PLIST'
        \(propertyList)
        PARBAKE_PLIST
        chown root:wheel \(propertyListPath).new
        chmod 0644 \(propertyListPath).new
        plutil -lint -s \(propertyListPath).new
        mv \(propertyListPath).new \(propertyListPath)
        launchctl bootout system/\(label) 2>/dev/null || true
        for attempt in 1 2 3 4 5; do
            if launchctl bootstrap system \(propertyListPath); then break; fi
            if [ "$attempt" = 5 ]; then exit 1; fi
            sleep 2
            launchctl bootout system/\(label) 2>/dev/null || true
        done

        """

    /// The command that leaves the agent binary on its standard input at `stagedPath`.
    public static let stageCommand = "umask 077 && cat > \(stagedPath) && chmod 0755 \(stagedPath)"

    /// The script that installs a staged agent in one SSH session of the provisioned account; the
    /// password reaches sudo through the script on ssh's standard input.
    public static func script(password: String) throws -> String {
        try ScriptInput.check(password, field: "password")
        return """
            set -eu
            IFS= read -r PARBAKE_PASSWORD <<'PARBAKE_PASSWORD'
            \(password)
            PARBAKE_PASSWORD
            PARBAKE_ROOT=$(cat <<'PARBAKE_ROOT'
            set -eu
            \(rootCommands)PARBAKE_ROOT
            )
            \(GuestCommands.asRoot)
            unset PARBAKE_PASSWORD
            echo '\(installedMarker)'

            """
    }
}
