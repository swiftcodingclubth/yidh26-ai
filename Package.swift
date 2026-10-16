// swift-tools-version: 6.2
// 6.2 so the package resolves in both Xcode 26 and Xcode 27.

import PackageDescription

let package = Package(
    name: "yidh26-ai",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HackathonAI", targets: ["HackathonAI"]),
    ],
    targets: [
        .target(name: "HackathonAI"),
        .testTarget(name: "HackathonAITests", dependencies: ["HackathonAI"]),
    ]
)
