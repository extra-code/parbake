// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationOCI
import Foundation

/// The part of a macOS virtual machine that the stop and wait logic needs.
public protocol GuestMachine: AnyObject, Sendable {
    var macAddress: String { get }
    var currentExit: GuestExit? { get }
    func start() async throws
    func requestStop() async throws
    func forceStop() async throws
    func wait() async -> GuestExit
    func wait(timeout: Duration) async -> GuestExit?
}

/// The part of the guest agent connection that the container operations need.
public protocol GuestAgentClient: Actor {
    func waitUntilReady(timeout: Duration) async throws -> String
    func createProcess(id: String, process: ContainerizationOCI.Process, stdio: [FileHandle?]) async throws
    func startProcess(id: String) async throws -> Int32
    func wait(id: String) async throws -> GuestExit
    func signal(id: String, signal: Int32) async throws
    func resize(id: String, columns: UInt32, rows: UInt32) async throws
    func shutDown(provisionedUsername: String?, timeout: Duration, note: (String) -> Void) async -> Bool
    func close() async
}

extension MacOSVirtualMachine: GuestMachine {}
extension GuestAgent: GuestAgentClient {}
