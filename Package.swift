// swift-tools-version: 6.2

import PackageDescription

/// What every target in this package is built with.
///
/// **`NonisolatedNonsendingByDefault`, since 2026-09-17.** A `nonisolated async`
/// function otherwise hops to the shared cooperative pool, whoever called it —
/// and the agent's request path is made of them, so a request on a thread of
/// its own would leave that thread at the first hop and run its SQLite on the
/// pool. Syd, asked whether to set it here or to add an isolation parameter to
/// each function on that path: "the package-wide setting". `Agent Performance
/// Overhaul.md`, *Staying on the request's thread*.
let everyTarget: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "PhotoGoRound",
    platforms: [
        // macOS 27 and later only. Syd, 2026-09-14: "upgrade everything to our
        // minimum support to macOS 27". Raise this line rather than writing an
        // availability guard when a newer API is the right answer.
        .macOS("27.0"),
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
        // A product only so the Xcode targets can link it. The two executables
        // are Xcode targets as well as package ones now, and an Xcode target
        // reaches a package's *products* — a bare target is invisible to it.
        .library(name: "Console", targets: ["Console"]),
        .executable(name: "photogoroundd", targets: ["photogoroundd"]),
        // Internal, and never shipped. It is a product so that `swift run
        // pgr_ctl` works; nothing about that puts it in a distributed bundle.
        .executable(name: "pgr_ctl", targets: ["pgr_ctl"]),
        // Installing, as code rather than as four shell scripts. The lasting
        // half: the menu-bar app links this when it becomes the installer, and
        // `pgr_install` is only the door an Install scheme's ⌘R knocks on until
        // then. macOS-only by nature — `launchctl`, `pluginkit` and
        // `~/Library/Screen Savers` mean nothing anywhere else.
        .library(name: "PhotoGoRoundInstall", targets: ["PhotoGoRoundInstall"]),
        // Runnable, because an aggregate target is not. Never shipped, and
        // expected to be replaced by the app that installs on first launch.
        .executable(name: "pgr_install", targets: ["pgr_install"]),
    ],
    targets: [
        .target(
            name: "PhotoGoRoundAgentAPI",
            swiftSettings: everyTarget
        ),
        .target(
            name: "PhotoGoRoundKit",
            dependencies: ["PhotoGoRoundAgentAPI"],
            swiftSettings: everyTarget
        ),
        .target(
            name: "PhotoGoRoundDisplay",
            // The client, not the kit: all it wants is the published port.
            dependencies: ["PhotoGoRoundAgentAPI"],
            swiftSettings: everyTarget
        ),
        // Terminal output, shared by the two executables and by nothing else.
        // It is deliberately outside the kit: unified logging is the shipping
        // mechanism and works from inside every sandbox we will ever be in,
        // while this is for a person with a terminal open.
        .target(
            name: "Console",
            swiftSettings: everyTarget
        ),
        .executableTarget(
            name: "photogoroundd",
            dependencies: ["PhotoGoRoundAgentAPI", "PhotoGoRoundKit", "Console"],
            // The dashboard's page, stylesheet and script. Not package
            // resources: the Xcode target copies them into the app bundle, and
            // `DashboardPage` reads them from here when there is no bundle.
            exclude: ["js"],
            swiftSettings: everyTarget
        ),
        // The rig. A separate binary because the service has exactly one job
        // and answering questions is not it.
        .executableTarget(
            name: "pgr_ctl",
            // `PhotoGoRoundDisplay` for the surfaces' own preferences — the
            // wallpaper's domain and `ShuffleInterval` — so `wallpaper set`
            // cannot disagree with what the app writes and the extension reads.
            dependencies: ["PhotoGoRoundAgentAPI", "PhotoGoRoundKit", "PhotoGoRoundDisplay", "Console"],
            // Consumed by the linker below, not copied into a bundle.
            exclude: ["Info.plist"],
            swiftSettings: everyTarget,
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
        .target(
            name: "PhotoGoRoundInstall",
            dependencies: ["PhotoGoRoundAgentAPI"],
            swiftSettings: everyTarget
        ),
        .executableTarget(
            name: "pgr_install",
            dependencies: ["PhotoGoRoundInstall", "Console"],
            swiftSettings: everyTarget
        ),
        .testTarget(
            name: "PhotoGoRoundInstallTests",
            dependencies: ["PhotoGoRoundInstall"],
            swiftSettings: everyTarget
        ),
        .testTarget(
            name: "PhotoGoRoundKitTests",
            dependencies: ["PhotoGoRoundAgentAPI", "PhotoGoRoundKit"],
            swiftSettings: everyTarget
        ),
        .testTarget(
            name: "PhotoGoRoundDisplayTests",
            dependencies: ["PhotoGoRoundAgentAPI", "PhotoGoRoundDisplay"],
            swiftSettings: everyTarget
        ),
        .testTarget(
            name: "photogorounddTests",
            dependencies: ["PhotoGoRoundAgentAPI", "photogoroundd"],
            swiftSettings: everyTarget
        ),
        .testTarget(
            name: "pgr_ctlTests",
            dependencies: ["PhotoGoRoundAgentAPI", "PhotoGoRoundDisplay", "pgr_ctl"],
            swiftSettings: everyTarget
        ),
    ]
)
