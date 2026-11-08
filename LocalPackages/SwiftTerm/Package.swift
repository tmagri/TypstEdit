// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Vendored copy of SwiftTerm (https://github.com/migueldeicaza/SwiftTerm)
// at tag v1.11.2, trimmed to the library only. TypstEdit uses it to host the
// Python pane's terminal: a real PTY-backed terminal view (ANSI/UTF-8,
// selection, Find, copy/paste) without pulling in SwiftTerm's example apps,
// benchmarks, docs, or its two build-time dependencies (swift-argument-parser
// and swift-docc-plugin) that only those extra targets needed.
//
// Only `Package.swift` differs from upstream: the products and targets are
// reduced to the single `SwiftTerm` library. The source files under
// `Sources/SwiftTerm` are unmodified. The MIT licence is in `LICENSE`, and
// THIRD_PARTY_NOTICES.md at the repository root credits the project.

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v13),
        .macOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
