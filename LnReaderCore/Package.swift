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
        // Dev tools: dump parsed m4b metadata / EPUB spine (swift run M4bDump|EpubDump <file>).
        .executableTarget(name: "M4bDump", dependencies: ["LnReaderCore"]),
        .executableTarget(name: "EpubDump", dependencies: ["LnReaderCore"]),
    ]
)
