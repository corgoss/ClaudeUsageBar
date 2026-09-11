// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageBarCore",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "ClaudeUsageBarCore", path: "app/Core"),
        .target(
            name: "ClaudeUsageBarAuth",
            dependencies: ["ClaudeUsageBarCore"],
            path: "app/Auth"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["ClaudeUsageBarCore"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "AccountStoreTests",
            dependencies: ["ClaudeUsageBarAuth"],
            path: "Tests/AccountStoreTests"
        ),
    ]
)