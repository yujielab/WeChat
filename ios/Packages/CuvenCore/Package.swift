// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CuvenCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "CuvenCore",
            targets: ["CuvenCore"]
        )
    ],
    targets: [
        .target(
            name: "CuvenCore",
            path: "Sources/CuvenCore"
        ),
        .testTarget(
            name: "CuvenCoreTests",
            dependencies: ["CuvenCore"],
            path: "Tests/CuvenCoreTests"
        )
    ]
)
