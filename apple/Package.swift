// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitWolf",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "GitWolf", targets: ["GitWolfApp"]),
        .library(name: "GitWolfCore", targets: ["GitWolfCore"]),
    ],
    dependencies: [
        // In-app updates: downloads, verifies (EdDSA) and installs new releases. See docs/RELEASING.md.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        // Git engine: process runner, parsers, graph layout, file watching.
        // Foundation + CoreServices only. No SwiftUI.
        .target(name: "GitWolfCore"),
        // SwiftUI application.
        .executableTarget(name: "GitWolfApp", dependencies: [
            "GitWolfCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        // Release tooling: update-signing keys, signing a release archive, writing the appcast.
        .executableTarget(name: "gitwolf-release", dependencies: ["GitWolfCore"], path: "Sources/GitWolfRelease"),
        .testTarget(name: "GitWolfCoreTests", dependencies: ["GitWolfCore"]),
    ]
)
