// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import RuntimeMacOS
import Virtualization

extension ParbakeTool {
    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a VM bundle and install macOS from a restore image"
        )

        @Option(name: .long, help: "Path of the VM bundle to create")
        var bundle: String

        @Option(name: .long, help: "Path of the restore image (.ipsw) to install")
        var ipsw: String

        @Option(name: .long, help: "Size of the sparse disk image in GiB")
        var diskSize: UInt64 = 100

        @Option(name: .long, help: "Format of the disk image: asif (macOS 27 or later host) or raw (default: asif where supported)")
        var diskFormat: MacOSVMBundle.DiskFormat = .preferred

        @Option(name: .long, help: "Number of CPUs during the installation")
        var cpus: Int = 4

        @Option(name: .long, help: "Memory in GiB during the installation")
        var memory: UInt64 = 8

        func run() async throws {
            let restoreImageURL = URL(fileURLWithPath: ipsw)
            let restoreImage = try await VZMacOSRestoreImage.image(from: restoreImageURL)
            guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration,
                requirements.hardwareModel.isSupported
            else {
                throw ValidationError("this host cannot run macOS \(restoreImage.operatingSystemVersion.string)")
            }

            print("Creating \(bundle) with a \(diskFormat.rawValue) disk for macOS \(restoreImage.operatingSystemVersion.string) (\(restoreImage.buildVersion))")
            let vmBundle = try MacOSVMBundle.create(
                at: URL(fileURLWithPath: bundle),
                hardwareModel: requirements.hardwareModel,
                diskSizeInBytes: diskSize << 30,
                diskFormat: diskFormat
            )

            let virtualMachine = try MacOSVirtualMachine(
                bundle: vmBundle,
                cpus: max(cpus, requirements.minimumSupportedCPUCount),
                memoryInBytes: max(memory << 30, requirements.minimumSupportedMemorySize)
            )

            print("Installing macOS, this takes a while")
            try await virtualMachine.install(restoreImageURL: restoreImageURL) { fraction in
                print("\r  \(Int(fraction * 100))%", terminator: "")
                fflush(stdout)
            }
            print("\nInstalled macOS into \(bundle)")
        }
    }
}

extension OperatingSystemVersion {
    var string: String { "\(majorVersion).\(minorVersion).\(patchVersion)" }
}

extension MacOSVMBundle.DiskFormat: ExpressibleByArgument {}
