// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Foundation
import Virtualization

/// The user account and login settings a macOS 27 or later guest applies on its first boot
/// after the restore, in place of the Setup Assistant.
///
/// The guest evaluates the settings only on that first boot; later boots ignore them.
public struct GuestProvisioning: Sendable {
    public var fullName: String
    public var username: String
    public var password: String
    public var logsInAutomatically: Bool
    public var enablesRemoteLogin: Bool

    public init(fullName: String, username: String, password: String, logsInAutomatically: Bool = true, enablesRemoteLogin: Bool = true) {
        self.fullName = fullName
        self.username = username
        self.password = password
        self.logsInAutomatically = logsInAutomatically
        self.enablesRemoteLogin = enablesRemoteLogin
    }

    /// Start options that carry the settings.
    ///
    /// Throws when Virtualization.framework rejects the full name, the username or the password;
    /// nothing has booted at that point.
    public func startOptions() throws -> VZMacOSVirtualMachineStartOptions {
        let options = VZMacGuestProvisioningOptions()
        options.fullName = fullName
        options.username = username
        options.password = password
        options.logsInAutomatically = logsInAutomatically
        options.enablesRemoteLogin = enablesRemoteLogin

        let startOptions = VZMacOSVirtualMachineStartOptions()
        do {
            try startOptions.setGuestProvisioning(options)
        } catch {
            throw ContainerizationError(.invalidArgument, message: "invalid guest provisioning: \(error.localizedDescription)", cause: error)
        }
        return startOptions
    }
}
