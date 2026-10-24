// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Foundation
import Testing

@testable import RuntimeMacOS

/// The text and code of the runtime's own errors, as the plugin and `parbake` print and forward them.
struct RuntimeFailureGoldenTests {
    /// How the plugin turns the error into the `ContainerizationError` the client sees.
    enum Site: Sendable {
        /// `RuntimeLifecycle.containerizationError(from:)`.
        case lifecycle
        /// The refusal of an instance whose overlay no longer stacks on its base.
        case incompatibleOverlay
        /// The start that waits for an agent that does not answer.
        case agentNotReady
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let make: @Sendable () -> any Error
        let description: String
        /// Where the plugin forwards the error with its own code and message, or `nil` when it reports something else instead.
        let forward: (site: Site, code: ContainerizationError.Code, message: String)?

        var testDescription: String { name }
    }

    static let overlaySuffix = "; set --label runtime-macos.on-incompatible-overlay=discard to start the instance over"
    static let notReadyPrefix = "the macOS guest started but its agent is not ready: "

    static let rows: [Row] = {
        let roots = "to ~/Library/Application Support/container-runtime-macos/bundle-roots"
        let notAbsolute = "bundle is not an absolute path"
        let outside =
            "/tmp/VM.bundle is outside the allowed bundle directories (/Users/u, /Volumes/v); add its parent directory as an absolute path on its own line \(roots)"
        let wrongOwner = "/Users/u/VM.bundle is not owned by the current user; use a bundle you own"
        let writable = "/Users/u/VM.bundle is writable by other users; run chmod go-w on it"
        let link = "/Users/u/VM.bundle/Disk.img links to /etc/hosts, outside the allowed bundle directories; link to a file inside them"
        let roots2 = "/Users/u/bundle-roots: line 2: x is not an absolute path"
        let overlay = "the overlay in /Users/u/VM.bundle does not stack on /Users/u/Base.bundle/Disk.img: the image is not a stack"
        let mismatch =
            "the guest agent reports version \"2 0.1.0\", this runtime speaks protocol 1; update the agent with parbake agent install"
        let lostCancelled = "lost process p1 in the guest: CancellationError()"
        return [
            Row(
                name: "notAbsolute", make: { makeNotAbsolute() }, description: notAbsolute, forward: (.lifecycle, .invalidArgument, notAbsolute)),
            Row(name: "outsideRoots", make: { makeOutsideRoots() }, description: outside, forward: (.lifecycle, .invalidArgument, outside)),
            Row(name: "wrongOwner", make: { makeWrongOwner() }, description: wrongOwner, forward: (.lifecycle, .invalidArgument, wrongOwner)),
            Row(name: "writableByOthers", make: { makeWritable() }, description: writable, forward: (.lifecycle, .invalidArgument, writable)),
            Row(name: "linkOutsideRoots", make: { makeLink() }, description: link, forward: (.lifecycle, .invalidArgument, link)),
            Row(name: "badRootsFile", make: { makeRootsFile() }, description: roots2, forward: (.lifecycle, .invalidArgument, roots2)),
            Row(
                name: "incompatibleOverlay", make: { makeOverlay() }, description: overlay, forward: (.incompatibleOverlay, .invalidState, overlay + overlaySuffix)),
            Row(
                name: "agentVersionMismatch", make: { makeMismatch() }, description: mismatch, forward: (.agentNotReady, .timeout, notReadyPrefix + mismatch)),
            Row(
                name: "processLost", make: { makeLost() }, description: lostCancelled, forward: nil),
        ]
    }()

    // The constructors of the values under test; the only lines that build the errors.
    static func makeNotAbsolute() -> any Error { RuntimeFailure.bundlePath(.notAbsolute("bundle")) }
    static func makeOutsideRoots() -> any Error { RuntimeFailure.bundlePath(.outsideRoots(path: "/tmp/VM.bundle", roots: ["/Users/u", "/Volumes/v"])) }
    static func makeWrongOwner() -> any Error { RuntimeFailure.bundlePath(.wrongOwner(path: "/Users/u/VM.bundle")) }
    static func makeWritable() -> any Error { RuntimeFailure.bundlePath(.writableByOthers(path: "/Users/u/VM.bundle")) }
    static func makeLink() -> any Error { RuntimeFailure.bundlePath(.linkOutsideRoots(file: "/Users/u/VM.bundle/Disk.img", target: "/etc/hosts")) }
    static func makeRootsFile() -> any Error {
        RuntimeFailure.bundlePath(.badRootsFile(path: "/Users/u/bundle-roots", reason: "line 2: x is not an absolute path"))
    }
    static func makeOverlay() -> any Error {
        RuntimeFailure.incompatibleOverlay(
            bundle: "/Users/u/VM.bundle", base: "/Users/u/Base.bundle/Disk.img",
            reason: "the image is not a stack")
    }
    static func makeMismatch() -> any Error { RuntimeFailure.agentVersionMismatch(agentVersion: "2 0.1.0") }
    static func makeLost() -> any Error { RuntimeFailure.processLost(id: "p1", cause: "\(CancellationError())") }

    /// What the plugin forwards for `error` at `site`. Only `.lifecycle` calls production code; the other two sites
    /// live in the plugin target, so this builds a copy of their message and pins the text, not the site.
    static func forwarded(_ error: any Error, at site: Site) -> ContainerizationError? {
        switch site {
        case .lifecycle:
            return RuntimeLifecycle.containerizationError(from: error) as? ContainerizationError
        case .incompatibleOverlay:
            return ContainerizationError(.invalidState, message: "\(error)" + overlaySuffix)
        case .agentNotReady:
            return ContainerizationError(.timeout, message: notReadyPrefix + "\(error)")
        }
    }

    @Test(arguments: rows)
    func testDescriptionIsPinned(row: Row) {
        let error = row.make()
        #expect("\(error)" == row.description)
        #expect(String(describing: error) == row.description)
    }

    @Test(arguments: rows.filter { $0.forward != nil })
    func testForwardedErrorIsPinned(row: Row) throws {
        let expected = try #require(row.forward)
        let forwarded = try #require(Self.forwarded(row.make(), at: expected.site))
        #expect(forwarded.code == expected.code)
        #expect(forwarded.message == expected.message)
    }

    @Test(arguments: [
        (3 as Int32?, "the macOS guest stopped with exit code 3 while process p1 ran; the process has no exit code"),
        (nil, "lost the guest agent's stream for process p1 while the guest kept running; its exit code is unknown"),
    ])
    func testLostProcessIsReportedAsInterrupted(row: (Int32?, String)) {
        #expect(RuntimeLifecycle.lostProcessMessage(processID: "p1", guestExitCode: row.0) == row.1)
    }
}
