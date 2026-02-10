// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodeEditLanguages",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "CodeEditLanguages",
            targets: ["CodeEditLanguages"]
        ),
    ],
    dependencies: [
        .package(path: "../SwiftTreeSitter"),
        .package(path: "../tree-sitter-typst"),
    ],
    targets: [
        .target(
            name: "CodeEditLanguages",
            dependencies: [
                "CodeLanguagesContainer", 
                "SwiftTreeSitter",
                .product(name: "TreeSitterTypst", package: "tree-sitter-typst")
            ],
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),

        .binaryTarget(
            name: "CodeLanguagesContainer",
            path: "CodeLanguagesContainer.xcframework.zip"
        ),

        .testTarget(
            name: "CodeEditLanguagesTests",
            dependencies: ["CodeEditLanguages"]
        ),
    ]
)
