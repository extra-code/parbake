// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ArgumentParser
import Foundation
import RuntimeMacOS
import Virtualization

extension ParbakeTool {
    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Boot a VM bundle in a window, for example to complete the Setup Assistant",
            discussion: "Shut down the guest from its Apple menu when you are done; the tool exits when the guest stops."
        )

        @Option(name: .long, help: "Path of the VM bundle to boot")
        var bundle: String

        @Option(name: .long, help: "Number of CPUs")
        var cpus: Int = 4

        @Option(name: .long, help: "Memory in GiB")
        var memory: UInt64 = 8

        @MainActor
        func run() async throws {
            let vmBundle = try MacOSVMBundle(url: URL(fileURLWithPath: bundle))
            let configuration = try MacOSVirtualMachine.configuration(bundle: vmBundle, cpus: cpus, memoryInBytes: memory << 30)
            let virtualMachine = VZVirtualMachine(configuration: configuration)

            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let window = SetupWindow(virtualMachine: virtualMachine, title: "macOS VM: \(vmBundle.url.lastPathComponent)")
            window.show()

            virtualMachine.start { result in
                if case .failure(let error) = result {
                    FileHandle.standardError.write(Data("failed to start the guest: \(error)\n".utf8))
                    Foundation.exit(1)
                }
            }
            app.activate()
            app.run()
        }
    }
}

/// A window that shows the guest's display and exits the tool when the guest stops.
///
/// Closing the window asks the guest to shut down instead of stopping it.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate, VZVirtualMachineDelegate {
    private let virtualMachine: VZVirtualMachine
    private let window: NSWindow

    init(virtualMachine: VZVirtualMachine, title: String) {
        self.virtualMachine = virtualMachine

        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = view
        super.init()

        window.delegate = self
        virtualMachine.delegate = self
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard virtualMachine.canRequestStop else {
            return true
        }
        try? virtualMachine.requestStop()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        virtualMachine.stop { _ in
            NSApplication.shared.terminate(nil)
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            NSApplication.shared.terminate(nil)
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        FileHandle.standardError.write(Data("the guest stopped with an error: \(error)\n".utf8))
        MainActor.assumeIsolated {
            NSApplication.shared.terminate(nil)
        }
    }
}
