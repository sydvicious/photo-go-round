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
        // What a client needs to talk to the agent, and nothing about how the
        // agent does its work. Preferences (which is how anything finds the
        // floating service port), where this deployment's container lives, the
        // value types the wire is made of, and the one file question the app is
        // better placed to answer than a round trip is.
        //
        // **It exists so the app can stop linking the kit.** The kit owns the
        // database, the cache, the deck, and — from Phase 2 — PhotoKit; none of
        // that belongs in a process whose entire job is drawing what it is
        // handed. See `Apple Photos Plan.md`.
        .library(name: "PhotoGoRoundAgentAPI", targets: ["PhotoGoRoundAgentAPI"]),
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
            name: "PhotoGoRoundAgentAPI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PhotoGoRoundKit",
            dependencies: ["PhotoGoRoundAgentAPI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PhotoGoRoundDisplay",
            // The client, not the kit: all it wants is the published port.
            dependencies: ["PhotoGoRoundAgentAPI"],
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
            dependencies: ["PhotoGoRoundAgentAPI", "PhotoGoRoundKit", "Console"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The rig. A separate binary because the service has exactly one job
        // and answering questions is not it.
        .executableTarget(
            name: "pgr_ctl",
            dependencies: ["PhotoGoRoundAgentAPI", "PhotoGoRoundKit", "Console"],
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
            dependencies: ["PhotoGoRoundAgentAPI", "PhotoGoRoundKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PhotoGoRoundDisplayTests",
            dependencies: ["PhotoGoRoundAgentAPI", "PhotoGoRoundDisplay"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "photogorounddTests",
            dependencies: ["PhotoGoRoundAgentAPI", "photogoroundd"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "pgr_ctlTests",
            dependencies: ["PhotoGoRoundAgentAPI", "pgr_ctl"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
