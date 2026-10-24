// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

/// The commands the host sends to a guest account, in one place.
public enum GuestCommands {
    /// Shuts the guest down with the account's passwordless sudo rule.
    public static let shutdown = "sudo -n /sbin/shutdown -h now"

    /// `shutdown` with its output discarded, for the end of a provisioning script.
    public static let shutdownDiscardingOutput = "sudo -n /sbin/shutdown -h now >/dev/null"

    /// What `shutdownIfAllowed` prints once sudo accepts the shutdown rule.
    public static let acceptedMarker = "parbake: shutting down"

    /// Shuts the guest down only if the sudo rule exists, printing `acceptedMarker` first.
    ///
    /// shutdown ends sshd, so the guest reports the acceptance before it runs shutdown.
    public static let shutdownIfAllowed =
        "sudo -n -l /sbin/shutdown >/dev/null && echo '\(acceptedMarker)' && sudo -n /sbin/shutdown -h now >/dev/null"

    /// The argv of `shutdown -h now`, run directly as root or through the account's passwordless sudo.
    public static func shutdownArguments(asRoot: Bool) -> [String] {
        asRoot ? ["/sbin/shutdown", "-h", "now"] : ["/usr/bin/sudo", "-n", "/sbin/shutdown", "-h", "now"]
    }

    /// The script fragment that runs `$PARBAKE_ROOT` as root with the password in `$PARBAKE_PASSWORD`.
    public static let asRoot = #"printf '%s\n' "$PARBAKE_PASSWORD" | sudo -S -p '' /bin/sh -c "$PARBAKE_ROOT""#
}
