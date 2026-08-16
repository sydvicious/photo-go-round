// swift-tools-version: 6.2

import PackageDescription

// No dependencies, and there never will be any. See PLAN.md, "No third-party
// dependencies, and what that means we write".
let package = Package(
    name: "PhotoGoRound",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "PhotoGoRoundKit", targets: ["PhotoGoRoundKit"]),
        .executable(name: "PhotoGoRoundServer", targets: ["PhotoGoRoundServer"]),
    ],
    targets: [
        .target(
            name: "PhotoGoRoundKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PhotoGoRoundServer",
            dependencies: ["PhotoGoRoundKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PhotoGoRoundKitTests",
            dependencies: ["PhotoGoRoundKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
