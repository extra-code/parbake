// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Logging
import RuntimeMacOS
import os

import struct Logging.Logger

/// Writes swift-log messages to the unified log under the `container-runtime-macos` subsystem.
///
/// The message and its metadata are logged as public text; the plugin logs no passwords or keys.
struct OSLogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata = Logger.Metadata()

    private let logger: os.Logger

    init(category: String) {
        self.logger = LogSubsystem.logger(category: category)
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let text = Self.render(message: event.message, metadata: metadata.merging(event.metadata ?? [:]) { $1 })
        logger.log(level: Self.osLogType(event.level), "\(text, privacy: .public)")
    }

    /// The message followed by its metadata as `[key=value]` pairs, sorted by key.
    static func render(message: Logger.Message, metadata: Logger.Metadata) -> String {
        guard !metadata.isEmpty else { return message.description }
        let pairs = metadata.sorted { $0.key < $1.key }.map { "[\($0.key)=\($0.value)]" }
        return ([message.description] + pairs).joined(separator: " ")
    }

    static func osLogType(_ level: Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug: .debug
        case .info, .notice: .info
        case .warning: .default
        case .error: .error
        case .critical: .fault
        }
    }
}
