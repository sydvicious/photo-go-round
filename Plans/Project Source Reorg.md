# Source code organization

I want to normalize the source code layout for this project. Each binary delivery gets its own folder, separated by platform. Each one has `Plans`, `Resources`, `Sources` and `Tests`,
when appropriate. Sources shared within the Mac sphere would be in a Shared folder, unless they are big enough to justify their own folder.

Sources shared across platforms follow the same rule but at the top level. The xcodeproject will have the iOS app and shared code as well as Mac code, so it belongs at the top level.



```
- iOS
-- Plans
MacOS
-- Plans
-- Agent
--- Sources
--- Tests
-- Desktop
--- Sources
--- Tests
-- Screensaver
--- Sources
--- Tests
-- Shared
--- Sources
--- Tests
-- Wallpaper
--- Sources
--- Tests
-- Widget
-- Sources
--- Tests

Shared
-- Plans
-- Sources
-- Tests


Audits
Documentation
Plans

Package.swift
Pacakge Tests.xctestplan
Photo-Go-Round.xcodeproj

CLAUDE.md
LICENSE
README.md
TODO.md
```

