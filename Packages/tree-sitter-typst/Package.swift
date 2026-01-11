// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "TreeSitterTypst",
    platforms: [.macOS(.v10_13), .iOS(.v11)],
    products: [
        .library(name: "TreeSitterTypst", targets: ["TreeSitterTypst"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "TreeSitterTypst",
                path: "src",
                exclude: [
                    "grammar.json",
                    "node-types.json",
                ],
                sources: [
                    "parser.c",
                    "scanner.c",
                ],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath(".")])
    ],
    cLanguageStandard: .c11
)
