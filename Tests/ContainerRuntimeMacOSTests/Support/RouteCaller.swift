// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerRuntimeClient
import ContainerXPC
import Foundation

/// Delivers a message to a route handler the way a peer would.
///
/// `XPCMessage.reply()` only works on a message that arrived over a connection, so the message goes
/// through an anonymous loopback connection first. The connections stay open for the handler's run.
///
///     let reply = try await callRoute(RuntimeRoutes.bootstrap.rawValue, handler: service.bootstrap)
func callRoute(
    _ route: String,
    configure: (XPCMessage) -> Void = { _ in },
    handler: (XPCMessage) async throws -> XPCMessage
) async throws -> XPCMessage {
    let outgoing = XPCMessage(route: route)
    configure(outgoing)

    let inbox = Inbox()
    let listener = xpc_connection_create(nil, nil)
    xpc_connection_set_event_handler(listener) { peer in
        guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
        inbox.hold(XPCMessage(object: peer))
        xpc_connection_set_event_handler(peer) { event in
            if xpc_get_type(event) == XPC_TYPE_DICTIONARY { inbox.deliver(XPCMessage(object: event)) }
        }
        xpc_connection_resume(peer)
    }
    xpc_connection_resume(listener)
    let client = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
    xpc_connection_set_event_handler(client) { _ in }
    xpc_connection_resume(client)
    defer {
        xpc_connection_cancel(client)
        xpc_connection_cancel(listener)
    }

    xpc_connection_send_message_with_reply(client, outgoing.underlying, nil) { _ in }
    let received = await inbox.next()
    return try await handler(received)
}

/// Hands the first message a loopback listener receives to the waiting test, and keeps the peer alive.
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [XPCMessage] = []
    private var message: XPCMessage?
    private var waiter: CheckedContinuation<XPCMessage, Never>?

    func hold(_ peer: XPCMessage) { lock.withLock { peers.append(peer) } }

    func deliver(_ event: XPCMessage) {
        let waiting = lock.withLock { () -> CheckedContinuation<XPCMessage, Never>? in
            if let waiter {
                self.waiter = nil
                return waiter
            }
            message = event
            return nil
        }
        waiting?.resume(returning: event)
    }

    func next() async -> XPCMessage {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> XPCMessage? in
                if let message { return message }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
