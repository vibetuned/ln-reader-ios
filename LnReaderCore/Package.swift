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
    targets: [
        .target(name: "LnReaderCore"),
        .testTarget(name: "LnReaderCoreTests", dependencies: ["LnReaderCore"]),
        // Temporary: framework-free check runnable with Command Line Tools only
        // (no XCTest until Xcode is installed). Remove once `swift test` works.
        .executableTarget(name: "SelfTest", dependencies: ["LnReaderCore"]),
    ]
)
