// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PhotoGoRound",
    platforms: [
        // TEMPORARY: the target is 27.0. Held at 26.0 only until 27 ships, so
        // the server can run on a second Mac that is on the current public
        // release rather than on this machine's seed.
        //
        // Nothing is designed around this. If a 27-only API is ever the right
        // answer, raise these two lines rather than writing an availability
        // guard — there is deliberately nothing else to unwind.
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "PhotoGoRoundKit", targets: ["PhotoGoRoundKit"]),
        .executable(name: "photogoroundd", targets: ["photogoroundd"]),
        // Internal, and never shipped. It is a product so that `swift run
        // pgr_ctl` works; nothing about that puts it in a distributed bundle.
        .executable(name: "pgr_ctl", targets: ["pgr_ctl"]),
    ],
    targets: [
        .target(
            name: "PhotoGoRoundKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Terminal output, shared by the two executables and by nothing else.
        // It is deliberately outside the kit: unified logging is the shipping
        // mechanism and works from inside every sandbox we will ever be in,
        // while this is for a person with a terminal open.
        .target(
            name: "Console",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Named the way a command-line service is named, even though it is an
        // agent rather than a daemon: `somethingd` is what a person expects to
        // find and to type.
        .executableTarget(
            name: "photogoroundd",
            dependencies: ["PhotoGoRoundKit", "Console"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The rig. A separate binary because the service has exactly one job
        // and answering questions is not it.
        .executableTarget(
            name: "pgr_ctl",
            dependencies: ["PhotoGoRoundKit", "Console"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PhotoGoRoundKitTests",
            dependencies: ["PhotoGoRoundKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "photogorounddTests",
            dependencies: ["photogoroundd"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "pgr_ctlTests",
            dependencies: ["pgr_ctl"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
