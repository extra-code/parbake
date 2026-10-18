// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The leases macOS's DHCP server hands to guests on the Virtualization.framework NAT network.
public enum DHCPLeases {
    public static let path = "/var/db/dhcpd_leases"

    /// The IPv4 address of the newest lease for `macAddress`, or nil when there is none.
    ///
    /// `leases` is the content of `/var/db/dhcpd_leases`: one `{ … }` block per lease, with
    /// `hw_address=1,<mac>` and the octets of the MAC written without leading zeros.
    public static func address(for macAddress: String, in leases: String) -> String? {
        let wanted = normalized(macAddress)
        var newest: (address: String, lease: UInt64)?
        for block in leases.components(separatedBy: "}") {
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                let pair = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if pair.count == 2 {
                    fields[String(pair[0])] = String(pair[1])
                }
            }
            guard let hardware = fields["hw_address"], let address = fields["ip_address"] else {
                continue
            }
            let mac = hardware.split(separator: ",", maxSplits: 1).last.map(String.init) ?? hardware
            guard normalized(mac) == wanted else {
                continue
            }
            let lease = fields["lease"].flatMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } ?? 0
            if newest == nil || lease >= newest!.lease {
                newest = (address, lease)
            }
        }
        return newest?.address
    }

    /// The IPv4 address of the newest lease for `macAddress` in the host's lease file.
    public static func currentAddress(for macAddress: String) -> String? {
        guard let leases = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return address(for: macAddress, in: leases)
    }

    static func normalized(_ macAddress: String) -> [Int] {
        macAddress.lowercased().split(separator: ":").compactMap { Int($0, radix: 16) }
    }
}
