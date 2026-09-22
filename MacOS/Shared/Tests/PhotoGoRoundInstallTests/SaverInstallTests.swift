import Foundation
import Testing

@testable import PhotoGoRoundInstall

/// The saver install's judgement, which is the half that can be tested without
/// touching a Mac: what it would name the bundle, what it would replace, and
/// which hosts it would stop.
///
/// The doing — the copy, the `killall` — is not here and cannot be; that is the
/// line the plan/apply split exists to draw.
@Suite("What installing a screensaver would do")
struct SaverInstallTests {

    private let savers = URL(filePath: "/tmp/pgr-test/Screen Savers")

    private func surroundings(
        present: [String] = [],
        running: [String] = []
    ) -> SaverInstall.Surroundings {
        let there = Set(present)
        let up = Set(running)
        return SaverInstall.Surroundings(
            directoryExists: { there.contains($0.path(percentEncoded: false)) },
            isRunning: { up.contains($0) }
        )
    }

    /// **The name is the bundle's, never a constant.** Each configuration builds
    /// a differently named saver, and a fixed name would remove another
    /// configuration's installed copy and then fail to find its own.
    @Test(
        "The installed name comes from the bundle it is handed",
        arguments: [
            "Photo-Go-Round Screensaver",
            "Photo-Go-Round Screensaver (Debug)",
            "Photo-Go-Round Screensaver (Claude)",
        ])
    func nameComesFromTheBundle(_ name: String) throws {
        let source = URL(filePath: "/build/Products/Debug/\(name).saver")
        let plan = try SaverInstall.plan(
            for: source, into: savers,
            surroundings: surroundings(present: [source.path(percentEncoded: false)]))
        #expect(plan.name == name)
        #expect(plan.destination == savers.appending(path: "\(name).saver"))
    }

    /// Three savers can sit in Screen Savers at once. An install touches the one
    /// of its own name and nothing else.
    @Test("Another configuration's installed saver is not what gets replaced")
    func replacesOnlyItsOwnName() throws {
        let source = URL(filePath: "/build/Photo-Go-Round Screensaver (Claude).saver")
        let othersInstalled = [
            savers.appending(path: "Photo-Go-Round Screensaver.saver"),
            savers.appending(path: "Photo-Go-Round Screensaver (Debug).saver"),
        ]
        let plan = try SaverInstall.plan(
            for: source, into: savers,
            surroundings: surroundings(
                present: [source.path(percentEncoded: false)]
                    + othersInstalled.map { $0.path(percentEncoded: false) }))
        #expect(plan.replacesExisting == false)
        #expect(!othersInstalled.contains(plan.destination))
    }

    @Test("Replacing is distinguished from installing")
    func replacingIsKnown() throws {
        let source = URL(filePath: "/build/Photo-Go-Round Screensaver (Debug).saver")
        let installed = savers.appending(path: "Photo-Go-Round Screensaver (Debug).saver")
        let fresh = try SaverInstall.plan(
            for: source, into: savers,
            surroundings: surroundings(present: [source.path(percentEncoded: false)]))
        #expect(fresh.replacesExisting == false)
        #expect(fresh.describedSteps.first?.hasPrefix("install ") == true)

        let over = try SaverInstall.plan(
            for: source, into: savers,
            surroundings: surroundings(
                present: [source.path(percentEncoded: false), installed.path(percentEncoded: false)]))
        #expect(over.replacesExisting)
        #expect(over.describedSteps.first?.hasPrefix("replace ") == true)
    }

    /// Both hosts cache a loaded bundle for the life of the process, so a
    /// rebuild runs the previous build until they are stopped. Only the ones
    /// actually running are named.
    @Test("Only the hosts that are running are listed for stopping")
    func onlyRunningHosts() throws {
        let source = URL(filePath: "/build/Photo-Go-Round Screensaver.saver")
        let present = [source.path(percentEncoded: false)]

        let none = try SaverInstall.plan(
            for: source, into: savers, surroundings: surroundings(present: present))
        #expect(none.hostsToStop.isEmpty)
        #expect(none.describedSteps.contains { $0.contains("no screensaver host is running") })

        let one = try SaverInstall.plan(
            for: source, into: savers,
            surroundings: surroundings(present: present, running: ["legacyScreenSaver"]))
        #expect(one.hostsToStop == ["legacyScreenSaver"])

        let both = try SaverInstall.plan(
            for: source, into: savers,
            surroundings: surroundings(
                present: present, running: ["legacyScreenSaver", "ScreenSaverEngine"]))
        #expect(both.hostsToStop == ["legacyScreenSaver", "ScreenSaverEngine"])
    }

    @Test("A missing bundle and a wrong kind of path are refused, and say which")
    func refusals() {
        let missing = URL(filePath: "/build/Photo-Go-Round Screensaver.saver")
        #expect(throws: SaverInstall.Failure.noBundle(missing)) {
            try SaverInstall.plan(for: missing, into: savers, surroundings: surroundings())
        }
        let app = URL(filePath: "/build/Photo-Go-Round.app")
        #expect(throws: SaverInstall.Failure.notASaverBundle(app)) {
            try SaverInstall.plan(
                for: app, into: savers,
                surroundings: surroundings(present: [app.path(percentEncoded: false)]))
        }
    }

    /// Where an install lands is the user's own Library, never `/Library`: an
    /// install is the owner's, and two people on one Mac keep their own.
    @Test("The destination is the user's own Screen Savers folder")
    func destinationIsPerUser() {
        let path = SaverInstall.destinationDirectory.path(percentEncoded: false)
        #expect(path.hasPrefix(URL.homeDirectory.path(percentEncoded: false)))
        #expect(path.hasSuffix("/Library/Screen Savers"))
    }
}
