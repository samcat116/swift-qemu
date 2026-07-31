// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "swift-qemu",
    // No API here needs a modern floor: the package is NIO, Subprocess and
    // System, all of which sit at macOS 13 or lower. The floor exists only so
    // the package builds, so keep it no higher than consumers need — a floor
    // above the consumer's own makes the product unlinkable there ("requires
    // minimum platform version 26.0 ... but this target supports 15.0"). 15.0
    // is the floor of the macOS host that drives QEMU via HVF.
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SwiftQEMU",
            targets: ["SwiftQEMU"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // Pinned exactly: SPM's `from:` will not resolve a pre-release, and
        // 1.0.0-beta.1 is the newest tag.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0-beta.1"),
        // Subprocess's `FilePath`/`FileDescriptor`. Declared explicitly rather than
        // leaned on transitively because the module is only named directly on
        // platforms without the OS `System` module — Linux, in CI.
        .package(url: "https://github.com/apple/swift-system", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SwiftQEMU",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .testTarget(
            name: "SwiftQEMUTests",
            dependencies: [
                "SwiftQEMU",
                // Test-only: `EmbeddedChannel` is how the QMP frame decoder is
                // driven without a socket.
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ]
)