// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "daimon",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "daimon", targets: ["daimon"]),
        .library(name: "DaimonCore", targets: ["DaimonCore"]),
        .library(name: "DaimonMCP", targets: ["DaimonMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "DaimonCore",
            exclude: ["Resources/system-prompt.md"],
            linkerSettings: [.linkedFramework("FoundationModels")],
            plugins: ["EmbedSystemPrompt"]
        ),
        .target(
            name: "DaimonMCP",
            dependencies: [
                "DaimonCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "daimon",
            dependencies: [
                "DaimonCore",
                "DaimonMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "DaimonCoreTests",
            dependencies: ["DaimonCore"]
        ),
        .testTarget(
            name: "DaimonMCPTests",
            dependencies: ["DaimonMCP"]
        ),
        .testTarget(
            name: "ModelEvalTests",
            dependencies: ["DaimonCore"]
        ),
        .plugin(
            name: "EmbedSystemPrompt",
            capability: .buildTool()
        ),
    ]
)
