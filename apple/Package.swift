// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitSync",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GitSync", targets: ["GitSyncApp"]),
        .library(name: "GitSyncCore", targets: ["GitSyncCore"]),
    ],
    targets: [
        // Git engine: process runner, parsers, graph layout, file watching.
        // Foundation + CoreServices only. No SwiftUI.
        .target(name: "GitSyncCore"),
        // SwiftUI application.
        .executableTarget(name: "GitSyncApp", dependencies: ["GitSyncCore"]),
        .testTarget(name: "GitSyncCoreTests", dependencies: ["GitSyncCore"]),
    ]
)
