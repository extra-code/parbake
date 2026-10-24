// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

/// `message` followed by the error that led to it, the way a `ContainerizationError` printed its cause.
func causedMessage(_ message: String, cause: any Error) -> String {
    "\(message) (cause: \"\(cause)\")"
}
