import Foundation
import Testing

@testable import PhotosGoRoundInstall

/// Reading `pluginkit`'s output and deciding which registrations are dead.
///
/// **This is the suite the plan was written to get.** Until 2026-09-19 the same
/// judgement was an unreadable `sed` expression and a shell loop, and the only
/// way to find out what it did was to run an install on a real Mac and look. It
/// had already been wrong once, in the way that costs somebody their
/// registration.
@Suite("Which wallpaper registrations are dead")
struct WallpaperInstallTests {

    /// Captured from this Mac on 2026-09-19, when a Claude build and Syd's
    /// Debug build were both registered. The second record's `((null))` version
    /// is real, not invented.
    private let captured = """
             com.sydpolk.photosgoround.wallpaper.claude.extension(0.1)\t28AB0040-D3D9-4207-AD43-E00A9C7903D8\t2026-09-19 22:07:04 +0000\t/Users/jazzman/.claude/build/photos-go-round/DerivedData/Build/Products/Claude/Photos-Go-Round Wallpaper Host.app/Contents/Extensions/Photos-Go-Round Wallpaper.appex
             com.sydpolk.photosgoround.wallpaper.debug.extension((null))\tB97DCD84-A346-45D9-BA29-98E5B943DCC2\t2026-09-19 17:26:45 +0000\t/Users/jazzman/Library/Developer/Xcode/DerivedData/Photos-Go-Round-heayruzwkexzulcighkingfxnpek/Build/Products/Debug/Photos-Go-Round Wallpaper Host.app/Contents/Extensions/Photos-Go-Round Wallpaper.appex
        """

    private let claude =
        "/Users/jazzman/.claude/build/photos-go-round/DerivedData/Build/Products/Claude/Photos-Go-Round Wallpaper Host.app/Contents/Extensions/Photos-Go-Round Wallpaper.appex"
    private let debug =
        "/Users/jazzman/Library/Developer/Xcode/DerivedData/Photos-Go-Round-heayruzwkexzulcighkingfxnpek/Build/Products/Debug/Photos-Go-Round Wallpaper Host.app/Contents/Extensions/Photos-Go-Round Wallpaper.appex"

    // MARK: - Reading pluginkit

    @Test("Both records are read, identifier and path exactly")
    func parsesCapturedOutput() {
        let read = WallpaperInstall.parseRegistrations(captured)
        #expect(read.count == 2)
        #expect(
            read[0] == .init(
                identifier: "com.sydpolk.photosgoround.wallpaper.claude.extension", path: claude,
                registered: Date(timeIntervalSince1970: 1_789_855_624)))
        #expect(
            read[1] == .init(
                identifier: "com.sydpolk.photosgoround.wallpaper.debug.extension", path: debug,
                registered: Date(timeIntervalSince1970: 1_789_838_805)))
    }

    /// The date is what says an app was replaced after its extension was
    /// registered, so a line whose date will not parse must still be read.
    @Test("A record whose date does not parse is still read, undated")
    func unparsableDateIsUndated() {
        let line = "     com.sydpolk.photosgoround.wallpaper.extension(0.1)\tUUID\tyesterday\t/Applications/Photos-Go-Round.app/Contents/Library/Wallpaper/Photos-Go-Round Wallpaper.appex"
        let read = WallpaperInstall.parseRegistrations(line)
        #expect(read.count == 1)
        #expect(read.first?.registered == nil)
    }

    /// **The bug the `sed` was written around.** Counting fields put `+0000 ` on
    /// the front of the path; taking everything from the first slash cannot.
    @Test("The date's timezone never leaks into the path")
    func timezoneDoesNotLeak() {
        for registration in WallpaperInstall.parseRegistrations(captured) {
            #expect(registration.path.hasPrefix("/Users/"))
            #expect(!registration.path.contains("+0000"))
            #expect(!registration.identifier.contains("("))
        }
    }

    @Test("Apple's own extensions and junk lines are read but not claimed as ours")
    func otherVendorsAreNotOurs() {
        let mixed = """
                 com.apple.wallpaper.extension.image(1.0)\tAAAA\t2026-01-01 00:00:00 +0000\t/System/Library/ExtensionKit/Extensions/WallpaperImageExtension.appex
            \(captured)
            a line with no path at all
            """
        let read = WallpaperInstall.parseRegistrations(mixed)
        #expect(read.count == 3)
        #expect(WallpaperInstall.isOurs("com.apple.wallpaper.extension.image") == false)
        #expect(WallpaperInstall.isOurs("com.sydpolk.photosgoround.wallpaper.extension"))
        #expect(WallpaperInstall.isOurs("com.sydpolk.photosgoround.wallpaper.debug.extension"))
        // Prefix alone is not enough: the host app shares it and is not an extension.
        #expect(WallpaperInstall.isOurs("com.sydpolk.photosgoround.wallpaper.debug") == false)
    }

    // MARK: - The judgement

    private func plan(
        appex: String,
        identifier: String,
        holds: [String: String],
        registered: [WallpaperInstall.Registration]
    ) throws -> WallpaperInstall.Plan {
        try WallpaperInstall.plan(
            for: URL(filePath: appex),
            surroundings: .init(
                directoryExists: { _ in true },
                identifierAt: { holds[$0] },
                registrations: { registered }))
    }

    /// **The hijack this rule exists to prevent.** An earlier version removed
    /// every copy sharing the identifier; measured 2026-09-15, that silently
    /// unregistered the copy another directory had installed, and the last
    /// build won. A live registration belonging to another build is left alone,
    /// whichever identity.
    @Test("Another configuration's live build is left alone, not unregistered")
    func liveElsewhereIsUntouched() throws {
        let made = try plan(
            appex: claude,
            identifier: "com.sydpolk.photosgoround.wallpaper.claude.extension",
            holds: [
                claude: "com.sydpolk.photosgoround.wallpaper.claude.extension",
                debug: "com.sydpolk.photosgoround.wallpaper.debug.extension",
            ],
            registered: WallpaperInstall.parseRegistrations(captured))
        #expect(made.toRemove.isEmpty)
        #expect(made.toLeave.map(\.path) == [debug])
        #expect(made.judged.first { $0.registration.path == claude }?.verdict == .ours)
    }

    @Test("A registration whose bundle is gone is removed")
    func bundleGoneIsRemoved() throws {
        let made = try plan(
            appex: claude,
            identifier: "com.sydpolk.photosgoround.wallpaper.claude.extension",
            holds: [claude: "com.sydpolk.photosgoround.wallpaper.claude.extension"],
            registered: WallpaperInstall.parseRegistrations(captured))
        #expect(made.toRemove.map(\.path) == [debug])
        #expect(made.judged.first { $0.registration.path == debug }?.verdict == .bundleGone)
    }

    /// What a rebuild at the same path under a new identity leaves behind — as
    /// Syd's Debug build did moving from `…wallpaper.extension` to
    /// `…wallpaper.debug.extension`.
    @Test("A registration whose bundle now holds something else is removed, and says what")
    func identifierChangedIsRemoved() throws {
        let made = try plan(
            appex: claude,
            identifier: "com.sydpolk.photosgoround.wallpaper.claude.extension",
            holds: [
                claude: "com.sydpolk.photosgoround.wallpaper.claude.extension",
                debug: "com.sydpolk.photosgoround.wallpaper.extension",
            ],
            registered: WallpaperInstall.parseRegistrations(captured))
        #expect(made.toRemove.map(\.path) == [debug])
        #expect(
            made.judged.first { $0.registration.path == debug }?.verdict
                == .identifierChanged(nowHolds: "com.sydpolk.photosgoround.wallpaper.extension"))
        #expect(made.describedSteps.contains { $0.contains("now holds com.sydpolk.photosgoround.wallpaper.extension") })
    }

    /// The same path re-registered under our own identifier is us, not a
    /// stranger, and is never removed on the way to registering it again.
    @Test("Our own registration is recognised as ours")
    func ourOwnIsOurs() throws {
        let made = try plan(
            appex: debug,
            identifier: "com.sydpolk.photosgoround.wallpaper.debug.extension",
            holds: [
                claude: "com.sydpolk.photosgoround.wallpaper.claude.extension",
                debug: "com.sydpolk.photosgoround.wallpaper.debug.extension",
            ],
            registered: WallpaperInstall.parseRegistrations(captured))
        #expect(made.toRemove.isEmpty)
        #expect(made.toLeave.map(\.path) == [claude])
    }

    @Test("Apple's registrations are never judged at all")
    func applesAreNotJudged() throws {
        let apple = WallpaperInstall.Registration(
            identifier: "com.apple.wallpaper.extension.image",
            path: "/System/Library/ExtensionKit/Extensions/WallpaperImageExtension.appex")
        let made = try plan(
            appex: claude,
            identifier: "com.sydpolk.photosgoround.wallpaper.claude.extension",
            holds: [claude: "com.sydpolk.photosgoround.wallpaper.claude.extension"],
            registered: [apple] + WallpaperInstall.parseRegistrations(captured))
        #expect(!made.judged.contains { $0.registration.identifier.hasPrefix("com.apple") })
    }

    // MARK: - Refusals

    @Test("A bundle that is not one of ours is refused, and says what it read")
    func refusesAnythingElse() {
        let stranger = URL(filePath: "/somewhere/Other.appex")
        #expect(throws: WallpaperInstall.Failure.notOurExtension(stranger, read: "com.example.thing")) {
            try WallpaperInstall.plan(
                for: stranger,
                surroundings: .init(
                    directoryExists: { _ in true },
                    identifierAt: { _ in "com.example.thing" },
                    registrations: { [] }))
        }
        #expect(
            String(describing: WallpaperInstall.Failure.notOurExtension(stranger, read: "com.example.thing"))
                .contains("com.example.thing"))
    }

    @Test("A missing bundle is refused before anything is read")
    func refusesMissingBundle() {
        let missing = URL(filePath: "/nowhere/Photos-Go-Round Wallpaper.appex")
        #expect(throws: WallpaperInstall.Failure.noBundle(missing)) {
            try WallpaperInstall.plan(
                for: missing,
                surroundings: .init(
                    directoryExists: { _ in false },
                    identifierAt: { _ in nil },
                    registrations: { [] }))
        }
    }
}
