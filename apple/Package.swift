// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitWolf",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "GitWolf", targets: ["GitWolfApp"]),
        .library(name: "GitWolfCore", targets: ["GitWolfCore"]),
    ],
    targets: [
        // Git engine: process runner, parsers, graph layout, file watching.
        // Foundation + CoreServices only. No SwiftUI.
        .target(name: "GitWolfCore"),
        // SwiftUI application.
        .executableTarget(name: "GitWolfApp", dependencies: ["GitWolfCore"]),
        .testTarget(name: "GitWolfCoreTests", dependencies: ["GitWolfCore"]),
    ]
)
