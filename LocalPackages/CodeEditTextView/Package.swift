// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodeEditTextView",
    platforms: [.macOS(.v13)],
    products: [
        // A Fast, Efficient text view for code.
        .library(
            name: "CodeEditTextView",
            targets: ["CodeEditTextView"]
        ),
    ],
    dependencies: [
        // Text mutation, storage helpers
        .package(path: "../TextStory"),
        // Useful data structures
        .package(path: "../swift-collections")
    ],
    targets: [
        // The main text view target.
        .target(
            name: "CodeEditTextView",
            dependencies: [
                "TextStory",
                .product(name: "Collections", package: "swift-collections"),
                "CodeEditTextViewObjC"
            ]
        ),

        // ObjC addons
        .target(
            name: "CodeEditTextViewObjC",
            publicHeadersPath: "include"
        ),

        // Tests for the text view
        .testTarget(
            name: "CodeEditTextViewTests",
            dependencies: [
                "CodeEditTextView"
            ]
        ),
    ]
)
