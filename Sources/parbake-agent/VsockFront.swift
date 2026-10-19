// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// Accepts vsock connections from the host only and relays each to the agent's gRPC server on a
/// Unix socket.
///
/// The gRPC transport reports no peer for a vsock connection, so it cannot tell the host from a
/// process inside the guest; without this check any guest user reaches a root agent.
final class VsockFront: Sendable {
    let port: UInt32
    let backend: String
    let allowedCID: UInt32
    private let listener: Int32

    init(port: UInt32, backend: String, allowedCID: UInt32 = UInt32(VMADDR_CID_HOST)) throws {
        let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw AgentError.posix("socket(AF_VSOCK)", errno)
        }
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_cid = UInt32(VMADDR_CID_ANY)
        address.svm_port = port
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_vm>.size)) }
        }
        guard bound == 0, Darwin.listen(listener, 16) == 0 else {
            let error = errno
            close(listener)
            throw AgentError.posix("listen on vsock port \(port)", error)
        }
        self.port = port
        self.backend = backend
        self.allowedCID = allowedCID
        self.listener = listener
    }

    /// Accepts connections on a thread of its own for the life of the process.
    func start() {
        Thread { [self] in
            while true {
                var peer = sockaddr_vm()
                var length = socklen_t(MemoryLayout<sockaddr_vm>.size)
                let connection = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
                }
                guard connection >= 0 else {
                    if errno != EINTR && errno != ECONNABORTED {
                        log("accept on vsock port \(port) failed: \(String(cString: strerror(errno)))")
                    }
                    continue
                }
                guard peer.svm_cid == allowedCID else {
                    log("refused a vsock connection from CID \(peer.svm_cid)")
                    close(connection)
                    continue
                }
                relay(connection)
            }
        }.start()
    }

    private func relay(_ connection: Int32) {
        let upstream = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            backend.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(capacity))) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard upstream >= 0, connected == 0 else {
            log("cannot reach the gRPC server at \(backend): \(String(cString: strerror(errno)))")
            close(connection)
            if upstream >= 0 {
                close(upstream)
            }
            return
        }
        let done = DispatchGroup()
        for (source, destination) in [(connection, upstream), (upstream, connection)] {
            done.enter()
            Thread {
                pump(from: source, to: destination)
                done.leave()
            }.start()
        }
        // Each descriptor is closed once both directions ended, so neither pump writes to a reused descriptor.
        done.notify(queue: .global()) {
            close(connection)
            close(upstream)
        }
    }
}

/// Copies `source` to `destination` until `source` ends, then ends the writing half of `destination`.
private func pump(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    copying: while true {
        let count = read(source, &buffer, buffer.count)
        if count < 0 && errno == EINTR {
            continue
        }
        guard count > 0 else {
            break
        }
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { write(destination, $0.baseAddress.map { $0 + offset }, count - offset) }
            if written < 0 && errno == EINTR {
                continue
            }
            guard written > 0 else {
                break copying
            }
            offset += written
        }
    }
    shutdown(destination, SHUT_WR)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("parbake-agent: \(message)\n".utf8))
}
