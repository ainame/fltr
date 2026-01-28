// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bokeh",
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
        // TUI - Reusable terminal UI library
        .target(
            name: "TUI",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "DisplayWidth", package: "swift-displaywidth"),
            ]
        ),

        // bokeh - Fuzzy finder executable
        .executableTarget(
            name: "bokeh",
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
            name: "bokehTests",
            dependencies: ["bokeh"]
        ),
    ]
)
