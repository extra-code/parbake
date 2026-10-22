// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import os

public enum LogSubsystem {
    public static let name = "container-runtime-macos"

    public static func logger(category: String) -> os.Logger {
        os.Logger(subsystem: name, category: category)
    }
}
