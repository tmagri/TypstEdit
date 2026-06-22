// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CSQLite",
    products: [
        .library(name: "CSQLite", targets: ["CSQLite"])
    ],
    targets: [
        .target(
            name: "CSQLite",
            path: "Sources/CSQLite",
            cSettings: [
                .define("SQLITE_ENABLE_LOAD_EXTENSION", to: "1"),
                .define("SQLITE_OMIT_LOAD_EXTENSION", to: "0")
            ]
        )
    ]
)
