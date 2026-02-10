// swift-tools-version: 5.5

import PackageDescription

let package = Package(
    name: "CodeEditSymbols",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "CodeEditSymbols",
            targets: ["CodeEditSymbols"]),
    ],
    dependencies: [
        .package(path: "../swift-snapshot-testing")
    ],
    targets: [
        .target(
            name: "CodeEditSymbols",
            dependencies: [],
            resources: [.process("Symbols.xcassets")]
        ),
        .testTarget(
            name: "CodeEditSymbolsTests",
            dependencies: [
                "CodeEditSymbols",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ]
        ),
    ]
)
