// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The preparation of a freshly provisioned guest account over SSH.
public enum GuestPreparation {
    /// The line the preparation script prints once everything before the shutdown succeeded.
    public static let preparedMarker = "parbake: prepared"

    /// The script that runs in the guest in one SSH session: it adds the public keys, allows
    /// the account to run `/sbin/shutdown` without a password, optionally turns Spotlight
    /// indexing off and empties the caches, and shuts the guest down.
    ///
    /// The password reaches sudo through the script on ssh's standard input.
    public static func script(username: String, password: String, publicKeys: [String], tidy: Bool) -> String {
        let userTidy = tidy ? "rm -rf \"$HOME\"/Library/Caches/* 2>/dev/null || true\n" : ""
        let rootTidy = tidy ? "mdutil -a -i off >/dev/null\nmdutil -a -E >/dev/null 2>&1 || true\nrm -rf /Library/Caches/* 2>/dev/null || true\n" : ""
        return """
            set -eu
            umask 077
            mkdir -p "$HOME/.ssh"
            cat >> "$HOME/.ssh/authorized_keys" <<'PARBAKE_KEYS'
            \(publicKeys.joined(separator: "\n"))
            PARBAKE_KEYS
            \(userTidy)IFS= read -r PARBAKE_PASSWORD <<'PARBAKE_PASSWORD'
            \(password)
            PARBAKE_PASSWORD
            PARBAKE_ROOT=$(cat <<'PARBAKE_ROOT'
            set -eu
            printf '%s ALL=(root) NOPASSWD: /sbin/shutdown\\n' '\(username)' > /etc/sudoers.d/parbake.new
            chmod 0440 /etc/sudoers.d/parbake.new
            visudo -cqf /etc/sudoers.d/parbake.new
            mv /etc/sudoers.d/parbake.new /etc/sudoers.d/parbake
            \(rootTidy)PARBAKE_ROOT
            )
            printf '%s\\n' "$PARBAKE_PASSWORD" | sudo -S -p '' /bin/sh -c "$PARBAKE_ROOT"
            unset PARBAKE_PASSWORD
            sudo -n -l /sbin/shutdown >/dev/null
            echo '\(preparedMarker)'
            sudo -n /sbin/shutdown -h now >/dev/null

            """
    }
}
