// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "parbake",
    platforms: [.macOS("27")],
    products: [
        .executable(name: "container-runtime-macos", targets: ["container-runtime-macos"]),
        .executable(name: "parbake", targets: ["parbake"]),
        .executable(name: "parbake-agent", targets: ["parbake-agent"]),
    ],
    dependencies: [
        // apple/container with the runtime-plugin commits that provide `[runtimeConfig]` in the plugin config.
        .package(url: "https://github.com/extra-code/container.git", revision: "0f8245481903d4db3fe701bbf0750924b450bc4d"),
        // Pinned to the containerization version that apple/container pins.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.53.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.10.1"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
        // The guest agent serves containerization's SandboxContext service over vsock.
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.9.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.36.0"),
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
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "ContainerLog", package: "container"),
                .product(name: "ContainerNetworkClient", package: "container"),
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
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "parbake-agent",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "RuntimeMacOS",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "RuntimeMacOSTests",
            dependencies: ["RuntimeMacOS"]
        ),
    ]
)
