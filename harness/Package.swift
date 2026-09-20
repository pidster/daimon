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
        // No tagged release yet; pinned to a commit so builds are reproducible (docs/backends.md).
        .package(
            url: "https://github.com/apple/coreai-models.git", revision: "3f109efd54273391f9fd9f5f5b3d8c6e99836d55"),
    ],
    targets: [
        .target(
            name: "DaimonCore",
            exclude: ["Resources/system-prompt.md"],
            linkerSettings: [.linkedFramework("FoundationModels")],
            plugins: ["EmbedSystemPrompt"]
        ),
        .target(
            name: "DaimonCoreAI",
            dependencies: [
                "DaimonCore",
                .product(name: "CoreAILM", package: "coreai-models"),
            ]
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
                "DaimonCoreAI",
                "DaimonMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "DaimonTestSupport",
            dependencies: ["DaimonCore"],
            path: "Tests/DaimonTestSupport"
        ),
        .testTarget(
            name: "DaimonCoreTests",
            dependencies: ["DaimonCore", "DaimonTestSupport"]
        ),
        .testTarget(
            name: "DaimonMCPTests",
            dependencies: ["DaimonMCP", "DaimonTestSupport"]
        ),
        .testTarget(
            name: "DaimonCoreAITests",
            dependencies: ["DaimonCoreAI", "DaimonTestSupport"]
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
