// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "swift-qemu",
    platforms: [
        .macOS(.v26)
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
            dependencies: ["SwiftQEMU"]
        ),
    ]
)