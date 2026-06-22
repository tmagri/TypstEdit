// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TypstEdit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // It's good practice to declare the executable product explicitly, though optional for simple CLI tools
        .executable(name: "TypstEdit", targets: ["TypstEdit"])
    ],
    dependencies: [
        .package(path: "LocalPackages/CodeEditSourceEditor"),
        .package(path: "LocalPackages/CSQLite"),
        .package(url: "https://github.com/sqliteai/sqlite-vector", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TypstEdit",
            dependencies: [
                "CodeEditSourceEditor",
                .product(name: "CSQLite", package: "CSQLite"),
                .product(name: "vector", package: "sqlite-vector")
            ],
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TypstEditTests",
            dependencies: ["TypstEdit"]
        ),
    ]
)