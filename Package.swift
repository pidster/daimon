// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "daimon",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "daimon", targets: ["daimon"]),
        .library(name: "DaimonCore", targets: ["DaimonCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "DaimonCore",
            linkerSettings: [.linkedFramework("FoundationModels")]
        ),
        .executableTarget(
            name: "daimon",
            dependencies: [
                "DaimonCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "DaimonCoreTests",
            dependencies: ["DaimonCore"]
        ),
    ]
)
