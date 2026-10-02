// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "parbake",
    platforms: [.macOS("15")],
    products: [
        .executable(name: "container-runtime-macos", targets: ["container-runtime-macos"]),
        .executable(name: "parbake", targets: ["parbake"]),
    ],
    dependencies: [
        // apple/container with the runtime-plugin commits that provide `[runtimeConfig]` in the plugin config.
        .package(url: "https://github.com/extra-code/container.git", revision: "0f8245481903d4db3fe701bbf0750924b450bc4d"),
        // Pinned to the containerization version that apple/container pins.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.53.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.10.1"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "container-runtime-macos",
            dependencies: [
                "RuntimeMacOS",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerLog", package: "container"),
                .product(name: "ContainerPlugin", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerRuntimeClient", package: "container"),
                .product(name: "ContainerXPC", package: "container"),
            ]
        ),
        .executableTarget(
            name: "parbake",
            dependencies: [
                "RuntimeMacOS",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "RuntimeMacOS",
            dependencies: [
                .product(name: "Containerization", package: "containerization")
            ]
        ),
        .testTarget(
            name: "RuntimeMacOSTests",
            dependencies: ["RuntimeMacOS"]
        ),
    ]
)
