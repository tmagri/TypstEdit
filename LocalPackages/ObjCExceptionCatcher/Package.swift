// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ObjCExceptionCatcher",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ObjCExceptionCatcher", targets: ["ObjCExceptionCatcher"])
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
        )
    ]
)
