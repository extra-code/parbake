// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An exclusive advisory lock on a file, held until `release()` or deallocation.
///
/// flock locks belong to the open file description, so a second `acquire` on the same path conflicts
/// even inside one process. The holder records its pid and command line in the lock file.
public final class FileLock: @unchecked Sendable {
    private let state = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    /// flock(LOCK_EX), with LOCK_NB when `wait` is false. A held lock without waiting throws
    /// RuntimeFailure.lockHeld(path:, holder:). The lock file records the holder's pid and command line.
    ///
    /// With `wait`, a lock that stays busy for more than a second prints "waiting for another <holder>" to stderr and then blocks.
    public static func acquire(_ url: URL, wait: Bool, holder: String) throws -> FileLock {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw RuntimeFailure.internalError("opening the lock file \(url.path) failed: \(String(cString: strerror(errno)))")
        }
        do {
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK else {
                    throw RuntimeFailure.internalError("locking \(url.path) failed: \(String(cString: strerror(errno)))")
                }
                guard wait else {
                    throw RuntimeFailure.lockHeld(path: url.path, holder: recordedHolder(fd))
                }
                try block(on: fd, path: url.path, notice: "waiting for another \(holder)")
            }
        } catch {
            close(fd)
            throw error
        }
        record(holder, in: fd)
        return FileLock(descriptor: fd)
    }

    /// Unlocks and closes the lock file. Calling it again does nothing.
    public func release() {
        state.lock()
        defer { state.unlock() }
        guard descriptor >= 0 else {
            return
        }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    private static func block(on fd: Int32, path: String, notice: String) throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            usleep(50_000)
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return
            }
        }
        FileHandle.standardError.write(Data((notice + "\n").utf8))
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw RuntimeFailure.internalError("locking \(path) failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    private static func record(_ holder: String, in fd: Int32) {
        let line = "\(holder) (pid \(getpid())): \(CommandLine.arguments.joined(separator: " "))\n"
        ftruncate(fd, 0)
        _ = line.withCString { pwrite(fd, $0, strlen($0), 0) }
    }

    private static func recordedHolder(_ fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            return nil
        }
        let text = String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
