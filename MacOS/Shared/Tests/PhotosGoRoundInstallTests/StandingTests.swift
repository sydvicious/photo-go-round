import Foundation
import Testing

@testable import PhotosGoRoundInstall

/// Whether what the app carries is already installed — the question a launch
/// asks before installing anything.
///
/// Every fact about the Mac is answered by the test, so nothing here looks at
/// launchd, `pkd` or a signature. `Plans/Release App Installer.md`, Phase 3.
@Suite("Whether what the app carries is already installed")
struct StandingTests {

    // MARK: - Agent

    private let server = URL(filePath: "/Applications/Photos-Go-Round.app/Contents/Helpers/Photos-Go-Round Server.app")
    private var binary: URL { server.appending(path: "Contents/MacOS/Photos-Go-Round Server") }
    private let label = "com.sydpolk.photosgoround.server"
    private let agents = URL(filePath: "/tmp/pgr-test/LaunchAgents")
    private var plist: URL { agents.appending(path: "\(label).plist") }

    private var agentSurroundings: AgentInstall.Surroundings {
        let label = label
        return AgentInstall.Surroundings(
            directoryExists: { _ in true },
            isExecutable: { _ in true },
            labelInBundle: { _ in label },
            isJobLoaded: { _ in true },
            runningAgents: { [] })
    }

    private func installed(job: JobDescription?, loaded: Bool = true) -> AgentInstall.Installed {
        AgentInstall.Installed(job: { _ in job }, isJobLoaded: { _ in loaded })
    }

    private func agentStanding(_ installed: AgentInstall.Installed) throws -> Standing {
        try AgentInstall.standing(
            of: server, launchAgents: agents, surroundings: agentSurroundings, installed: installed)
    }

    @Test("No job description is an agent not installed")
    func noPlistIsMissing() throws {
        #expect(try agentStanding(installed(job: nil)) == .missing)
    }

    @Test("The job this bundle would write, loaded, is current")
    func theSameJobIsCurrent() throws {
        let job = JobDescription(label: label, program: binary)
        #expect(try agentStanding(installed(job: job)) == .current)
    }

    /// Another copy of the app — a second archive somewhere else — wrote it.
    @Test("A job running another copy's binary differs, and names it")
    func anotherBinaryDiffers() throws {
        let elsewhere = URL(filePath: "/Volumes/Disk Image/Photos-Go-Round.app/Contents/Helpers/Photos-Go-Round Server.app/Contents/MacOS/Photos-Go-Round Server")
        let job = JobDescription(label: label, program: elsewhere)
        let standing = try agentStanding(installed(job: job))
        #expect(standing == .differs("the job runs \(elsewhere.path(percentEncoded: false))"))
    }

    /// An older app wrote a job description this one would not — the change
    /// from `Background` to `Adaptive` on 2026-09-17 is the kind of thing.
    @Test("A job description an older app wrote differs, though it runs the same binary")
    func anOlderDescriptionDiffers() throws {
        var job = JobDescription(label: label, program: binary)
        job.processType = "Background"
        #expect(try agentStanding(installed(job: job)).needsInstall)
    }

    @Test("A job description launchd has not loaded differs")
    func notLoadedDiffers() throws {
        let job = JobDescription(label: label, program: binary)
        #expect(try agentStanding(installed(job: job, loaded: false)) == .differs("the job is not loaded"))
    }

    @Test("A bundle that is not an agent is refused before anything is compared")
    func brokenBundleThrows() {
        let broken = AgentInstall.Surroundings(
            directoryExists: { _ in true }, isExecutable: { _ in true },
            labelInBundle: { _ in nil }, isJobLoaded: { _ in true }, runningAgents: { [] })
        #expect(throws: AgentInstall.Failure.noLabel(server)) {
            try AgentInstall.standing(
                of: server, launchAgents: agents, surroundings: broken,
                installed: installed(job: nil))
        }
    }

    // MARK: - Saver

    private let savers = URL(filePath: "/tmp/pgr-test/Screen Savers")
    private let saver = URL(filePath: "/Applications/Photos-Go-Round.app/Contents/Resources/Photos-Go-Round Screensaver.saver")

    private func saverStanding(_ there: SaverInstall.Installed) throws -> Standing {
        let saverPath = saver.path(percentEncoded: false)
        return try SaverInstall.standing(
            of: saver, into: savers,
            surroundings: SaverInstall.Surroundings(
                directoryExists: { $0.path(percentEncoded: false) == saverPath },
                isRunning: { _ in false }),
            installed: { _ in there })
    }

    @Test("Nothing in Screen Savers is not installed")
    func saverMissing() throws {
        #expect(try saverStanding(.nothing) == .missing)
    }

    /// **What an app replaced at the same path finds, and it is right as it
    /// stands.** Syd, 2026-09-21: over an existing install, "screensaver —
    /// nothing needs to change".
    @Test("A link to this very saver is current")
    func saverLinkedHere() throws {
        #expect(try saverStanding(.link(to: saver.path(percentEncoded: false))) == .current)
    }

    @Test("A link to another copy of the app differs, and names it")
    func saverLinkedElsewhere() throws {
        let other = "/Volumes/Disk Image/Photos-Go-Round.app/Contents/Resources/Photos-Go-Round Screensaver.saver"
        #expect(try saverStanding(.link(to: other)) == .differs("linked to \(other)"))
    }

    /// What `pgr_install saver` lays down from a build directory.
    @Test("A copy of the same name differs: the app installs a link, never a copy")
    func saverCopyDiffers() throws {
        #expect(try saverStanding(.bundle) == .differs("a copy is installed, not a link"))
    }

    // MARK: - The saver on disk

    /// A real directory in a temporary folder, so `installed(at:)` reads the
    /// filesystem rather than being told.
    @Test("A link, a dangling link, a real bundle and nothing are told apart")
    func installedReadsTheDisk() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "pgr-standing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let bundle = folder.appending(path: "real.saver")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let link = folder.appending(path: "link.saver")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
        let dangling = folder.appending(path: "dangling.saver")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: folder.appending(path: "gone.saver"))

        #expect(SaverInstall.installed(at: bundle) == .bundle)
        #expect(SaverInstall.installed(at: link) == .link(to: bundle.path(percentEncoded: false)))
        // **The case `fileExists` gets wrong**: it follows the link and says
        // there is nothing, and then no link can be made over it.
        #expect(SaverInstall.installed(at: dangling) == .link(to: folder.appending(path: "gone.saver").path(percentEncoded: false)))
        #expect(SaverInstall.installed(at: folder.appending(path: "absent.saver")) == .nothing)
    }

    @Test("Linking replaces a dangling link and names the saver it was given")
    func applyLinkOverADanglingLink() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "pgr-standing-\(UUID().uuidString)")
        let savers = folder.appending(path: "Screen Savers")
        try FileManager.default.createDirectory(at: savers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "App.app/Contents/Resources/Photos-Go-Round Screensaver.saver")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let destination = savers.appending(path: "Photos-Go-Round Screensaver.saver")
        try FileManager.default.createSymbolicLink(
            at: destination, withDestinationURL: folder.appending(path: "Deleted.app/x.saver"))

        let plan = try SaverInstall.plan(
            for: source, into: savers,
            surroundings: .init(directoryExists: { _ in true }, isRunning: { _ in false }))
        try SaverInstall.applyLink(plan)
        #expect(SaverInstall.installed(at: destination) == .link(to: source.path(percentEncoded: false)))
    }

    // MARK: - Wallpaper

    private let appex = URL(filePath: "/Applications/Photos-Go-Round.app/Contents/Library/Wallpaper/Photos-Go-Round Wallpaper.appex")
    private let identifier = "com.sydpolk.photosgoround.wallpaper.extension"

    private func wallpaperStanding(
        _ registered: [WallpaperInstall.Registration], changed: Date? = nil
    ) throws -> Standing {
        let identifier = identifier
        return try WallpaperInstall.standing(
            of: appex,
            surroundings: WallpaperInstall.Surroundings(
                directoryExists: { _ in true },
                identifierAt: { _ in identifier },
                registrations: { registered },
                changedAt: { _ in changed }))
    }

    @Test("Registered from this very appex is current")
    func wallpaperCurrent() throws {
        let ours = WallpaperInstall.Registration(identifier: identifier, path: appex.path(percentEncoded: false))
        #expect(try wallpaperStanding([ours]) == .current)
    }

    /// **An app replaced at the same path.** The registration still names the
    /// right place and describes the old bundle. Syd, 2026-09-21: "unregister
    /// the extension, re-register the extension, tickle Wallpaper agent".
    @Test("Registered here before the appex last changed differs")
    func wallpaperReplacedSinceRegistered() throws {
        let registered = Date(timeIntervalSince1970: 1_790_000_000)
        let ours = WallpaperInstall.Registration(
            identifier: identifier, path: appex.path(percentEncoded: false), registered: registered)
        #expect(
            try wallpaperStanding([ours], changed: registered.addingTimeInterval(60))
                == .stale("replaced since it was registered"))
        #expect(try wallpaperStanding([ours], changed: registered.addingTimeInterval(-60)) == .current)
    }

    /// Re-registering restarts `WallpaperAgent`, which the person sees; doing
    /// it on every launch because a date would not parse would be worse.
    @Test("A registration with no date, or an appex whose change cannot be read, is current")
    func wallpaperUnknownAgeIsCurrent() throws {
        let undated = WallpaperInstall.Registration(identifier: identifier, path: appex.path(percentEncoded: false))
        #expect(try wallpaperStanding([undated], changed: Date()) == .current)
        let dated = WallpaperInstall.Registration(
            identifier: identifier, path: appex.path(percentEncoded: false), registered: Date())
        #expect(try wallpaperStanding([dated], changed: nil) == .current)
    }

    // MARK: - The chosen wallpaper

    /// The shape `WallpaperAgent`'s store had on 2026-09-21, reduced to the
    /// keys that lead to a choice.
    private func store(_ provider: String, under key: String = "AllSpacesAndDisplays") -> Data {
        var root: [String: Any] = ["Spaces": [String: Any](), "Displays": [String: Any]()]
        root[key] = ["Desktop": ["Content": ["Choices": [["Provider": provider, "Files": [Any]()]]]]]
        return try! PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    @Test("This extension chosen for all displays, or as the system default, is chosen", arguments: ["AllSpacesAndDisplays", "SystemDefault", "Spaces"])
    func chosenAnywhere(_ key: String) {
        #expect(WallpaperInstall.isChosen(identifier, store: store(identifier, under: key)))
    }

    @Test("Another wallpaper, or another configuration's extension, is not this one chosen")
    func otherChoicesAreNot() {
        #expect(!WallpaperInstall.isChosen(identifier, store: store("com.apple.wallpaper.choice.image")))
        #expect(
            !WallpaperInstall.isChosen(
                identifier, store: store("com.sydpolk.photosgoround.wallpaper.debug.extension")))
    }

    /// A registration nobody asked for is the worse mistake.
    @Test("A store that is missing or unreadable counts as not chosen")
    func unreadableStoreIsNotChosen() {
        #expect(!WallpaperInstall.isChosen(identifier, store: nil))
        #expect(!WallpaperInstall.isChosen(identifier, store: Data("not a plist".utf8)))
    }

    // MARK: - The running extension

    private func mismatch(_ running: [WallpaperInstall.Running], changed: Date?) -> String? {
        let identifier = identifier
        return WallpaperInstall.mismatch(
            of: appex, running: running,
            surroundings: WallpaperInstall.Surroundings(
                directoryExists: { _ in true },
                identifierAt: { $0.contains("Debug") ? "com.sydpolk.photosgoround.wallpaper.debug.extension" : identifier },
                registrations: { [] },
                changedAt: { _ in changed }))
    }

    private let replacedAt = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("None running is no mismatch")
    func noneRunning() {
        #expect(mismatch([], changed: replacedAt) == nil)
    }

    @Test("Running from this appex, started after it last changed, matches")
    func runningHereMatches() {
        let here = WallpaperInstall.Running(
            pid: 7, appex: appex.path(percentEncoded: false), started: replacedAt.addingTimeInterval(60))
        #expect(mismatch([here], changed: replacedAt) == nil)
    }

    /// An app replaced under a running extension.
    @Test("Running from this appex, started before it was replaced, does not match")
    func runningStaleDoesNotMatch() {
        let stale = WallpaperInstall.Running(
            pid: 7, appex: appex.path(percentEncoded: false), started: replacedAt.addingTimeInterval(-60))
        #expect(mismatch([stale], changed: replacedAt) == "pid 7 started before its appex was replaced")
    }

    @Test("Running from another copy of the app does not match, and says where")
    func runningElsewhereDoesNotMatch() {
        let other = "/Volumes/Disk Image/Photos-Go-Round.app/Contents/Library/Wallpaper/Photos-Go-Round Wallpaper.appex"
        let elsewhere = WallpaperInstall.Running(pid: 8, appex: other, started: replacedAt.addingTimeInterval(60))
        #expect(mismatch([elsewhere], changed: replacedAt) == "pid 8 runs from \(other)")
    }

    /// Syd's Debug extension running beside a Release app is not the Release
    /// app's business.
    @Test("Another configuration's running extension is passed over")
    func otherConfigurationIsPassedOver() {
        let debug = WallpaperInstall.Running(
            pid: 9, appex: "/Users/x/DerivedData/Debug/Photos-Go-Round Wallpaper.appex", started: nil)
        #expect(mismatch([debug], changed: replacedAt) == nil)
    }

    @Test("A start time that cannot be read counts as a mismatch")
    func unreadableStartMismatches() {
        let unknown = WallpaperInstall.Running(pid: 7, appex: appex.path(percentEncoded: false), started: nil)
        #expect(mismatch([unknown], changed: replacedAt) != nil)
    }

    @Test("Not registered at all is not installed")
    func wallpaperMissing() throws {
        #expect(try wallpaperStanding([]) == .missing)
    }

    @Test("Registered from another copy differs, and names where")
    func wallpaperElsewhere() throws {
        let other = "/Volumes/Disk Image/Photos-Go-Round.app/Contents/Extensions/Photos-Go-Round Wallpaper.appex"
        let standing = try wallpaperStanding([.init(identifier: identifier, path: other)])
        #expect(standing == .differs("registered from \(other)"))
    }

    /// Debug and Claude builds register beside Release, and are not this one.
    @Test("Another configuration's registration does not count as this one's")
    func otherConfigurationIsNotOurs() throws {
        let debug = WallpaperInstall.Registration(
            identifier: "com.sydpolk.photosgoround.wallpaper.debug.extension",
            path: "/elsewhere/Photos-Go-Round Wallpaper.appex")
        #expect(try wallpaperStanding([debug]) == .missing)
    }

    // MARK: - The live facts

    /// Ordering, not timing: the file is made by this test, so it cannot have
    /// changed before the process running the test started.
    @Test("A file made by this process changed after this process started")
    func liveCtimeFollowsStart() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "pgr-standing-\(UUID().uuidString)")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let started = try #require(CodeIdentity.startedAt(getpid()))
        let changed = try #require(CodeIdentity.changedAt(file))
        #expect(changed > started)
    }
}
