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
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "0.3.0"),
    ],
    targets: [
        // fltr - Fuzzy finder executable
        .executableTarget(
            name: "fltr",
            dependencies: [
                "FltrLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),

        // FltrLib - Lib code for fltr
        .target(
            name: "FltrLib",
            dependencies: [
                "TUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
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

        // FltrCSystem - C system library shims for cross-platform POSIX APIs
        .target(
            name: "FltrCSystem",
            dependencies: []
        ),

        // Demo - Interactive TUI widget gallery
        .executableTarget(
            name: "tui-demo",
            dependencies: [
                "TUI",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/Demo",
            exclude: ["README.md"]
        ),

        // Benchmarks
        .executableTarget(
            name: "matcher-benchmark",
            dependencies: ["FltrLib"],
            path: "Sources/Benchmarks"
        ),

        // Tests
        .testTarget(
            name: "fltrTests",
            dependencies: ["fltr"]
        ),
    ]
)
