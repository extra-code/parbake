// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Foundation
import Testing

@testable import RuntimeMacOS

/// The text and code of the errors the VM, agent client, bundle and validation code throws.
///
/// A row that runs the real site names it in the test; a row that builds the error itself pins the
/// text of a site that needs a running guest or a failing system call.
struct RuntimeMacOSErrorTextTests {
    /// The text a caller prints for `error`: a `ContainerizationError`'s message with its cause, or a `RuntimeFailure`'s description.
    private func text(of error: any Error) -> String {
        if let failure = error as? RuntimeFailure {
            return failure.description
        }
        if let wrapped = error as? ContainerizationError {
            return wrapped.errorDescription ?? wrapped.message
        }
        return "\(error)"
    }

    private func code(of error: any Error) -> ContainerizationError.Code? {
        if let failure = error as? RuntimeFailure {
            return failure.containerizationCode
        }
        return (error as? ContainerizationError)?.code
    }

    private func thrown(_ body: () async throws -> Void) async -> any Error {
        do {
            try await body()
        } catch {
            return error
        }
        Issue.record("nothing was thrown")
        return CancellationError()
    }

    private func expect(_ error: any Error, _ expected: ContainerizationError.Code, _ message: String, prefix: Bool = false) {
        #expect(code(of: error) == expected)
        if prefix {
            #expect(text(of: error).hasPrefix(message))
        } else {
            #expect(text(of: error) == message)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("error-text-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func bundleDirectory() throws -> URL {
        let directory = try temporaryDirectory()
        for name in MacOSVMBundle.fileNames {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    // MARK: Validated

    @Test
    func testAControlCharacterInAScriptInput() async {
        let error = await thrown { try ScriptInput.check("a\nb", field: "full name") }
        expect(error, .invalidArgument, "full name must not contain control characters")
    }

    @Test
    func testTheReservedPrefixInAScriptInput() async {
        let error = await thrown { try ScriptInput.check("xPARBAKE_y", field: "password") }
        expect(error, .invalidArgument, "password must not contain the text PARBAKE_")
    }

    // MARK: FileLock

    @Test
    func testALockFileThatCannotBeOpened() async throws {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID())/lock")
        let error = await thrown { _ = try FileLock.acquire(url, wait: false, holder: "test") }
        expect(error, .internalError, "opening the lock file \(url.path) failed: No such file or directory")
    }

    @Test
    func testAFailedLockCall() {
        expect(failedLock(path: "/tmp/x.lock"), .internalError, "locking /tmp/x.lock failed: Bad file descriptor")
    }

    // MARK: MacOSVirtualMachine

    @Test
    func testAHardwareModelThatCannotBeRead() async throws {
        let directory = try bundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try MacOSVMBundle(url: directory)
        let error = await thrown { _ = try MacOSVirtualMachine.configuration(bundle: bundle, cpus: 2, memoryInBytes: 4 << 30) }
        expect(error, .invalidArgument, "invalid hardware model in \(directory.path)")
    }

    @Test
    func testTheRemainingConfigurationAndVsockSites() {
        expect(unsupportedHardware(path: "/b"), .unsupported, "this host does not support the hardware model in /b")
        expect(badMachineIdentifier(path: "/b"), .invalidArgument, "invalid machine identifier in /b")
        expect(badMACAddress("zz"), .invalidArgument, "invalid MAC address zz")
        expect(noVsockDevice(), .invalidState, "the virtual machine has no vsock device")
        expect(vsockTimeout(port: 1024), .timeout, "the guest did not connect to vsock port 1024")
    }

    // MARK: GuestAgent

    @Test
    func testAnUnknownProcess() async {
        let agent = GuestAgent(versionProbe: { nil })
        let error = await thrown { _ = try await agent.wait(id: "p1") }
        expect(error, .notFound, "process p1 does not exist")
    }

    @Test
    func testTheAgentSites() {
        expect(processNotStarted(id: "p1"), .invalidState, "process p1 is not started")
        expect(processTimeout(args: ["/bin/sleep", "9"], timeout: .seconds(5)), .timeout, "/bin/sleep 9 did not finish within 5.0 seconds")
        expect(
            agentUnreachable(cause: ProbeError("refused")), .invalidState,
            "the guest agent does not answer on vsock port 1024; install it with parbake agent install (cause: \"refused\")")
    }

    // MARK: MacOSVMBundle

    @Test
    func testAnIncompleteInstanceIsRefusedOnOpen() async throws {
        let directory = try bundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = directory.appendingPathComponent(MacOSVMBundle.diskImageName)
        try FileManager.default.removeItem(at: disk)
        try FileManager.default.createSymbolicLink(at: disk, withDestinationURL: directory.appendingPathComponent(MacOSVMBundle.hardwareModelName))
        let error = await thrown { _ = try MacOSVMBundle(url: directory) }
        expect(error, .invalidState, "\(directory.path) is an incomplete instance; remove the container")
    }

    @Test
    func testAnIncompleteInstanceIsRefusedOnAttach() async throws {
        let directory = try bundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try MacOSVMBundle(url: directory)
        let disk = directory.appendingPathComponent(MacOSVMBundle.diskImageName)
        try FileManager.default.removeItem(at: disk)
        try FileManager.default.createSymbolicLink(at: disk, withDestinationURL: directory.appendingPathComponent(MacOSVMBundle.hardwareModelName))
        let error = await thrown { _ = try bundle.storageDeviceAttachment() }
        expect(error, .invalidState, "\(directory.path) is an incomplete instance; remove the container")
    }

    @Test
    func testAnInstanceIsNoSourceForAnInstanceOrALayer() async throws {
        let directory = try bundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent(MacOSVMBundle.overlayImageName))
        let bundle = try MacOSVMBundle(url: directory)
        let destination = directory.appendingPathExtension("copy")
        let instance = await thrown { _ = try bundle.instance(at: destination) }
        expect(instance, .unsupported, "\(directory.path) is a container's instance, not a bundle")
        let layer = await thrown { _ = try bundle.layerBundle(at: destination) }
        expect(layer, .unsupported, "\(directory.path) is a container's instance, not a bundle")
    }

    @Test
    func testADiskImageThatCannotBeOpened() async throws {
        let directory = try bundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try MacOSVMBundle(url: directory)
        let error = await thrown { _ = try bundle.instance(at: directory.appendingPathExtension("copy")) }
        expect(error, .invalidArgument, "cannot open the disk image of \(directory.path)", prefix: true)
    }

    @Test
    func testARawDiskImage() async throws {
        let directory = try bundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(count: 1 << 20).write(to: directory.appendingPathComponent(MacOSVMBundle.diskImageName))
        let bundle = try MacOSVMBundle(url: directory)
        let error = await thrown { _ = try bundle.instance(at: directory.appendingPathExtension("copy")) }
        expect(
            error, .unsupported, "\(directory.path) has a raw disk image; rebuild it with parbake create, which creates an ASIF disk image")
    }

    @Test
    func testTheBundleSitesThatNeedAFailingSystemCall() {
        let cause = ProbeError("disk full")
        expect(bundleExists(path: "/b"), .exists, "/b already exists")
        expect(createFailed(path: "/b/Disk.img", cause: cause), .internalError, "failed to create /b/Disk.img (cause: \"disk full\")")
        expect(moveFailed(from: "/s", to: "/d", cause: cause), .internalError, "failed to move /s to /d (cause: \"disk full\")")
        expect(cloneFailed(from: "/s", to: "/d", cause: cause), .internalError, "failed to clone /s to /d (cause: \"disk full\")")
        expect(copyFailed(from: "/s", to: "/d", cause: cause), .internalError, "failed to copy /s to /d (cause: \"disk full\")")
        expect(layerOfLayer(path: "/b"), .unsupported, "/b is a layer bundle; a layer stacks on a base bundle only")
    }

    @Test
    func testAnOverlayThatDoesNotStackOnItsDiskImage() async throws {
        let directory = try bundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not an image".utf8).write(to: directory.appendingPathComponent(MacOSVMBundle.overlayImageName))
        let bundle = try MacOSVMBundle(url: directory)
        let error = await thrown { _ = try bundle.storageDeviceAttachment() }
        expect(error, .invalidState, "the overlay in \(directory.path) does not stack on ", prefix: true)
        #expect(text(of: error).contains("(cause: \""))
    }

    // MARK: GuestProvisioning

    @Test
    func testRejectedProvisioningNamesTheFrameworkReason() async {
        let error = await thrown { _ = try GuestProvisioning(fullName: "CI", username: "ci", password: "").startOptions() }
        expect(error, .invalidArgument, "invalid guest provisioning: ", prefix: true)
        #expect(text(of: error).contains("(cause: \""))
    }
}

// Text pins: the helpers below build each error in the test and pin a copy of the text of a site that needs a
// running guest or a failing system call. They do not run the production site.

private func failedLock(path: String) -> any Error {
    RuntimeFailure.internalError("locking \(path) failed: \(String(cString: strerror(EBADF)))")
}

private func unsupportedHardware(path: String) -> any Error {
    RuntimeFailure.unsupported("this host does not support the hardware model in \(path)")
}

private func badMachineIdentifier(path: String) -> any Error {
    RuntimeFailure.invalidArgument("invalid machine identifier in \(path)")
}

private func badMACAddress(_ address: String) -> any Error {
    RuntimeFailure.invalidArgument("invalid MAC address \(address)")
}

private func noVsockDevice() -> any Error {
    RuntimeFailure.invalidState("the virtual machine has no vsock device")
}

private func vsockTimeout(port: UInt32) -> any Error {
    RuntimeFailure.timeout("the guest did not connect to vsock port \(port)")
}

private func processNotStarted(id: String) -> any Error {
    RuntimeFailure.invalidState("process \(id) is not started")
}

private func processTimeout(args: [String], timeout: Duration) -> any Error {
    RuntimeFailure.timeout("\(args.joined(separator: " ")) did not finish within \(timeout)")
}

private func agentUnreachable(cause: any Error) -> any Error {
    RuntimeFailure.invalidState(
        causedMessage("the guest agent does not answer on vsock port 1024; install it with parbake agent install", cause: cause))
}

private func bundleExists(path: String) -> any Error {
    RuntimeFailure.exists("\(path) already exists")
}

private func createFailed(path: String, cause: any Error) -> any Error {
    RuntimeFailure.internalError(causedMessage("failed to create \(path)", cause: cause))
}

private func moveFailed(from: String, to: String, cause: any Error) -> any Error {
    RuntimeFailure.internalError(causedMessage("failed to move \(from) to \(to)", cause: cause))
}

private func cloneFailed(from: String, to: String, cause: any Error) -> any Error {
    RuntimeFailure.internalError(causedMessage("failed to clone \(from) to \(to)", cause: cause))
}

private func copyFailed(from: String, to: String, cause: any Error) -> any Error {
    RuntimeFailure.internalError(causedMessage("failed to copy \(from) to \(to)", cause: cause))
}

private func layerOfLayer(path: String) -> any Error {
    RuntimeFailure.unsupported("\(path) is a layer bundle; a layer stacks on a base bundle only")
}

