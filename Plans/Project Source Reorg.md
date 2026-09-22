# Source code organization

I want to normalize the source code layout for this project. Each binary delivery gets its own folder, separated by platform. Each one has `Plans`, `Resources`, `Sources` and `Tests`,
when appropriate. Sources shared within the Mac sphere would be in a Shared folder, unless they are big enough to justify their own folder.

Sources shared across platforms follow the same rule but at the top level. The xcodeproject will have the iOS app and shared code as well as Mac code, so it belongs at the top level.



```
iOS
-- Plans
MacOS
-- Plans
-- Agent
--- Dashboard
---- Resources
---- Sources
---- Tests
--- Endpoints
---- Sources
---- Tests
--- Resources
--- Sources
--- Tests
-- Desktop
--- Sources
--- Tests
-- Screensaver
--- Resources
--- Sources
--- Tests
-- Shared
--- Sources
--- Tests
-- Tools
--- pgr_ctl
--- pgr_install
-- Wallpaper
--- Resources
--- Sources
--- Tests
-- Widget
--- Sources
--- Tests

Shared
-- Plans
-- Sources
-- Tests
--- Support

Audits
Config
Documentation
Plans
Scripts

Package.swift
Package Tests.xctestplan
Photo-Go-Round.xcodeproj

CLAUDE.md
LICENSE
README.md
TODO.md
```

# Where things go

Decided 2026-09-22.

| Now | Goes to |
|---|---|
| `Sources/photogoroundd`, `app/agent/Info.plist`, `Tests/photogorounddTests` | `MacOS/Agent`; see *The agent* |
| `app/mac/Sources`, `app/tests` | `MacOS/Desktop` |
| `app/saver` | `MacOS/Screensaver` |
| `app/wallpaper-extension`, `app/wallpaper-host` | `MacOS/Wallpaper` |
| `PhotoGoRoundKit`, `PhotoGoRoundInstall`, `Console` and their tests | `MacOS/Shared` |
| `PhotoGoRoundAgentAPI`, `PhotoGoRoundDisplay` and their tests | `Shared` |
| `Sources/pgr_ctl`, `Sources/pgr_install`, `Tests/pgr_ctlTests` | `MacOS/Tools` |
| `app/Photo-Go-Round.xcodeproj`, `Tests/Package Tests.xctestplan` | top level |
| `app/Config/Version.xcconfig` | `Config` |
| `Tests/Support/ScratchPreferences.swift`, `app/tests/ScratchPreferences.swift` | one copy, in `Shared/Tests/Support` |
| `audits` | `Audits` |

- **Two passes: move, then rename.** The reorganization only moves files; the build and tests pass, and Syd commits. The product rename is a separate change after it.
- **`PhotoGoRoundKit` becomes `PhotosGoRoundKit`**, in the rename pass. It stays in `MacOS/Shared` until another platform needs it; then it moves to `Shared`.
- **The extension and its host share `MacOS/Wallpaper/Sources`.** All nine files in one folder; each target's membership exceptions exclude the other's files. The two plists are `Resources/Extension-Info.plist` and `Resources/Host-Info.plist`, beside `Photo-Go-Round Wallpaper.entitlements`.
- **`Scripts` stays at the top level.**
- **The agent.** Decided 2026-09-22, after the first move. `Service` is gone.
  - `Dashboard`: `DashboardEndpoint` and `DashboardPage` in `Sources`, the page, stylesheet and script in `Resources`, `DashboardEndpointTests` in `Tests`.
  - `Endpoints`: the picture, photos and source endpoints in `Sources`; `PhotosEndpointTests`, `SourceEndpointTests` and `EndpointCacheTests` in `Tests`.
  - Everything else stays in `Sources` and `Tests`. `Resources` holds only `Info.plist`.
  - The package keeps one agent target and one agent test target, each rooted at `MacOS/Agent` and listing its three folders.

