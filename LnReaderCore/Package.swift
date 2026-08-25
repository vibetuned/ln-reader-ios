// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LnReaderCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LnReaderCore", targets: ["LnReaderCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "LnReaderCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "LnReaderCoreTests", dependencies: ["LnReaderCore"]),
        // Dev tool: dump parsed metadata/chapters of an m4b (swift run m4bdump <file>).
        .executableTarget(name: "M4bDump", dependencies: ["LnReaderCore"]),
    ]
)
