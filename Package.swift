// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PhotoGoRound",
    platforms: [
        // macOS is held at 26.0 so the server runs on a second Mac that is
        // kept off betas; the target is 27.0. Raise this line rather than
        // writing an availability guard when a 27-only API is the right
        // answer — there is deliberately nothing else to unwind.
        .macOS("26.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "PhotoGoRoundKit", targets: ["PhotoGoRoundKit"]),
        // What a surface needs to show a picture: the client that asks for
        // one, and the geometry of drawing it. Separate from the kit because
        // the kit is the library half and knows nothing about being looked
        // at — and separate from the app because the Phase 6 screensaver
        // links the same fit and the same pan rather than reimplementing
        // what this phase was supposed to have rehearsed.
        .library(name: "PhotoGoRoundDisplay", targets: ["PhotoGoRoundDisplay"]),
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
        .target(
            name: "PhotoGoRoundDisplay",
            dependencies: ["PhotoGoRoundKit"],
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
            // Consumed by the linker below, not copied into a bundle.
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            // A bare Mach-O has no Info.plist, and TCC denies a Photos request
            // from a process that carries no usage string — instantly, with no
            // prompt, which reads exactly like a refusal the user typed. The
            // section is how a command-line tool gets one. `photos-spike` is
            // the only thing here that needs it.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/pgr_ctl/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "PhotoGoRoundKitTests",
            dependencies: ["PhotoGoRoundKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PhotoGoRoundDisplayTests",
            dependencies: ["PhotoGoRoundDisplay"],
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
