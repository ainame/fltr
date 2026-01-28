// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "fltr",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-system", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/ainame/swift-displaywidth", branch: "main"),
    ],
    targets: [
        // FltrCSystem - C system library shims for cross-platform POSIX APIs
        .target(
            name: "FltrCSystem",
            dependencies: []
        ),

        // TUI - Reusable terminal UI library
        .target(
            name: "TUI",
            dependencies: [
                "FltrCSystem",
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "DisplayWidth", package: "swift-displaywidth"),
            ]
        ),

        // fltr - Fuzzy finder executable
        .executableTarget(
            name: "fltr",
            dependencies: [
                "TUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "DisplayWidth", package: "swift-displaywidth"),
            ]
        ),

        // Tests
        .testTarget(
            name: "fltrTests",
            dependencies: ["fltr"]
        ),
    ]
)
