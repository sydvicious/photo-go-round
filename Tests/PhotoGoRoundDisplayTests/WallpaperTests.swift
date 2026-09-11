import Foundation
import Testing

#if canImport(AppKit)
import AppKit
#endif

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundDisplay

/// The wallpaper's loop, driven without touching anybody's desktop.
///
/// Every edge the wallpaper has — the displays attached, the call that sets a
/// desktop, the clock, the preference domain, the directory — is handed in, so
/// what is asserted here is the rule and not AppKit. Whether the desktop really
/// changes, and how Spaces behave, are answered by running it; see
/// `Wallpaper Plan.md`, *Testing*.
@Suite("The wallpaper")
@MainActor
struct WallpaperTests {

    /// A source that answers however a test needs it to, and remembers every
    /// question it was asked.
    private final class Stub: PictureSource, @unchecked Sendable {
        enum Answer {
            case picture(Data, String)
            case empty
            case failure(PictureClient.Failure)
        }

        struct Ask: Equatable {
            let consumer: String
            let displayID: String?
            let box: PixelSize?
        }

        private let lock = NSLock()
        private var answer: Answer
        private var asked: [Ask] = []

        init(_ answer: Answer) { self.answer = answer }

        var asks: [Ask] { lock.withLock { asked } }
        func answers(_ next: Answer) { lock.withLock { answer = next } }

        func next(
            consumer: String, displayID: String?, fitting box: PixelSize?
        ) async throws -> ServedPicture? {
            let answer = lock.withLock { () -> Answer in
                asked.append(Ask(consumer: consumer, displayID: displayID, box: box))
                return self.answer
            }
            switch answer {
            case .picture(let data, let type): return ServedPicture(data: data, contentType: type)
            case .empty: return nil
            case .failure(let failure): throw failure
            }
        }
    }

    /// The desktop, as the calls that were made to it.
    private final class Desktop {
        var sets: [(file: URL, display: String)] = []
        var refuses = false
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(minutes: Double) { now += minutes * 60 }
    }

    private final class Screens {
        var list: [WallpaperDisplay]
        init(_ list: [WallpaperDisplay]) { self.list = list }
    }

    private static let big = WallpaperDisplay(id: "A", pixels: PixelSize(width: 3840, height: 2160))
    private static let small = WallpaperDisplay(id: "B", pixels: PixelSize(width: 2560, height: 1440))

    /// One wallpaper over one scratch domain and one scratch directory. A second
    /// `make()` over the same rig is the same wallpaper after a relaunch.
    private final class Rig {
        let source: Stub
        let desktop = Desktop()
        let clock = Clock()
        let screens: Screens
        let directory = URL.temporaryDirectory.appending(path: "pgr-wallpaper-\(UUID().uuidString)")
        let suite = scratchSuiteName("wallpaper")
        let interval: Duration
        let retry: Duration

        init(
            _ answer: Stub.Answer, displays: [WallpaperDisplay],
            interval: Duration = .seconds(30 * 60), retry: Duration = .seconds(60)
        ) {
            source = Stub(answer)
            screens = Screens(displays)
            self.interval = interval
            self.retry = retry
            // Through the preference, as `defaults write` would, so every test
            // here also exercises the path the real interval takes.
            UserDefaults(suiteName: suite)!.set(interval.totalSeconds, forKey: "intervalSeconds")
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
            discardScratchSuite(suite)
        }

        /// `recheck` defaults to a day, so the rule's own waits are what a test
        /// sees; `recheckCapsTheSleep` is the one that asks for the real cap.
        @MainActor
        func make(source: Stub? = nil, recheck: Duration = .seconds(24 * 60 * 60)) -> Wallpaper {
            Wallpaper(
                source: source ?? self.source,
                directory: directory,
                defaults: UserDefaults(suiteName: suite)!,
                retry: retry,
                recheck: recheck,
                displays: { [screens] in screens.list },
                setDesktop: { [desktop] file, id in
                    if desktop.refuses { throw Wallpaper.Failure.displayGone(id) }
                    desktop.sets.append((file, id))
                },
                now: { [clock] in clock.now })
        }

        var files: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [])
                .sorted()
        }
    }

    private static let heic = Data("pretend this is a photograph".utf8)
    private static let other = Data("and this is another".utf8)

    /// Waits for something to become true, rather than sleeping a guess.
    private static func until(
        _ reached: @MainActor () -> Bool, _ what: String, within limit: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if reached() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(what) did not happen within \(limit)")
    }

    /// Long enough for a loop that is going to ask to have asked.
    private static func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    /// Waits for the first picture to be **set**, not merely asked for.
    ///
    /// The ask is recorded before the picture comes back, so a test that moved
    /// on at the ask was racing the rest of the round: the first version of the
    /// untick test found nothing set yet, and the wake test advanced the clock
    /// while the picture was in flight — which then stamped the later time on
    /// the record, so the display was correctly *not* due. Once the set is seen
    /// the round has finished, because nothing after it awaits.
    private static func firstPictureSet(_ rig: Rig) async throws {
        try await until({ rig.desktop.sets.count == 1 }, "a first picture set")
    }

    // MARK: - Asking

    @Test("Each display is asked for as the wallpaper, at its own size, under its own identity")
    func asksPerDisplay() async {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big, Self.small])
        _ = await rig.make().round()

        #expect(rig.source.asks == [
            .init(consumer: "wallpaper", displayID: "A", box: PixelSize(width: 3840, height: 2160)),
            .init(consumer: "wallpaper", displayID: "B", box: PixelSize(width: 2560, height: 1440)),
        ])
    }

    // MARK: - The files

    /// **Setting the URL already on screen does not redraw**, measured
    /// 2026-09-10, so every change has to name the file that is not showing.
    @Test("The picture goes into the display's file that is not on screen, and that file becomes the desktop")
    func filesAlternate() async throws {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let wallpaper = rig.make()

        _ = await wallpaper.round()
        let first = rig.directory.appending(path: "A-a.heic")
        #expect(try Data(contentsOf: first) == Self.heic)
        #expect(rig.desktop.sets.map(\.file) == [first])
        #expect(rig.desktop.sets.map(\.display) == ["A"])

        rig.clock.advance(minutes: 31)
        rig.source.answers(.picture(Self.other, "image/heic"))
        _ = await wallpaper.round()
        let second = rig.directory.appending(path: "A-b.heic")
        #expect(try Data(contentsOf: second) == Self.other)
        #expect(rig.desktop.sets.last?.file == second)

        rig.clock.advance(minutes: 31)
        _ = await wallpaper.round()
        #expect(rig.desktop.sets.last?.file == first)
        #expect(rig.files == ["A-a.heic", "A-b.heic"])
    }

    @Test("The file's extension follows what was served, and the side alternates")
    func filenames() {
        #expect(Wallpaper.filename(for: "A", contentType: "image/heic", after: nil) == "A-a.heic")
        #expect(Wallpaper.filename(for: "A", contentType: "image/jpeg", after: nil) == "A-a.jpeg")
        #expect(
            Wallpaper.filename(for: "A", contentType: "image/heic", after: URL(filePath: "/x/A-a.heic"))
                == "A-b.heic")
        #expect(
            Wallpaper.filename(for: "A", contentType: "image/heic", after: URL(filePath: "/x/A-b.heic"))
                == "A-a.heic")
    }

    #if canImport(AppKit)
    /// **The fill colour is System Settings'**, measured 2026-09-10: leaving it
    /// out keeps whatever the user chose, and a colour of ours would overwrite it.
    @Test("The options carry scaling and clipping and no fill colour")
    func noFillColour() {
        let options = Wallpaper.fitOptions()
        #expect(Set(options.keys) == [.imageScaling, .allowClipping])
        #expect((options[.imageScaling] as? NSNumber)?.uintValue
            == NSImageScaling.scaleProportionallyUpOrDown.rawValue)
        #expect((options[.allowClipping] as? NSNumber)?.boolValue == false)
    }
    #endif

    // MARK: - Nothing to give

    @Test("An empty library leaves the desktop alone")
    func emptyLeavesItAlone() async {
        let rig = Rig(.empty, displays: [Self.big])
        let wallpaper = rig.make()
        _ = await wallpaper.round()

        #expect(rig.desktop.sets.isEmpty)
        #expect(rig.files.isEmpty)
        #expect(wallpaper.record(for: "A") == nil)
    }

    @Test("An absent agent leaves the desktop alone")
    func absentLeavesItAlone() async {
        let rig = Rig(.failure(.noPortPublished), displays: [Self.big])
        let wallpaper = rig.make()
        _ = await wallpaper.round()

        #expect(rig.desktop.sets.isEmpty)
        #expect(rig.files.isEmpty)
        #expect(wallpaper.record(for: "A") == nil)
    }

    @Test("A picture already set survives a request for that display that comes up empty")
    func pictureSurvivesEmpty() async {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let wallpaper = rig.make()
        _ = await wallpaper.round()
        let record = wallpaper.record(for: "A")

        rig.clock.advance(minutes: 31)
        rig.source.answers(.empty)
        _ = await wallpaper.round()

        #expect(rig.desktop.sets.count == 1)
        #expect(wallpaper.record(for: "A") == record)
    }

    @Test("A display that got nothing is asked again after the retry, not the interval")
    func shortfallRetries() async {
        let rig = Rig(.empty, displays: [Self.big])
        let wallpaper = rig.make()
        #expect(await wallpaper.round() == rig.retry)

        rig.source.answers(.picture(Self.heic, "image/heic"))
        let wait = await wallpaper.round()
        #expect(abs(wait.totalSeconds - rig.interval.totalSeconds) < 1)
    }

    @Test("The change time is stored only after the desktop was set")
    func storedOnlyAfterSetting() async {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        rig.desktop.refuses = true
        let wallpaper = rig.make()

        #expect(await wallpaper.round() == rig.retry)
        #expect(wallpaper.record(for: "A") == nil)
        #expect(wallpaper.isDue("A"))
    }

    // MARK: - Which displays are due

    @Test("Displays come due independently: one due and one not changes only the first")
    func independentDisplays() async {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let wallpaper = rig.make()
        _ = await wallpaper.round()

        rig.screens.list = [Self.big, Self.small]
        rig.clock.advance(minutes: 10)
        _ = await wallpaper.round()

        #expect(rig.source.asks.map(\.displayID) == ["A", "B"])
        let wait = await wallpaper.round()
        // A is next, twenty minutes after its change ten minutes ago.
        #expect(abs(wait.totalSeconds - 20 * 60) < 1)
    }

    @Test("A stored time in the future, and one whose file is gone, both count as due")
    func strangeRecordsAreDue() async throws {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let wallpaper = rig.make()
        _ = await wallpaper.round()
        #expect(!wallpaper.isDue("A"))

        rig.clock.advance(minutes: -60)
        #expect(wallpaper.isDue("A"), "a clock set back held the display")

        rig.clock.advance(minutes: 60)
        #expect(!wallpaper.isDue("A"))
        let file = try #require(wallpaper.record(for: "A")).file
        try FileManager.default.removeItem(at: file)
        #expect(wallpaper.isDue("A"), "a missing file held the display")
    }

    // MARK: - Launching

    /// Syd: "the image should not be changed before the time interval … even
    /// if the binary was just started up" — and "put the stored files back at
    /// launch."
    @Test("A launch that is not due asks for nothing and puts each stored file back")
    func launchNotDue() async throws {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let first = rig.make()
        _ = await first.round()
        let file = try #require(first.record(for: "A")).file

        rig.clock.advance(minutes: 10)
        let fresh = Stub(.picture(Self.other, "image/heic"))
        let relaunched = rig.make(source: fresh)
        relaunched.setEnabled(true)
        defer { relaunched.setEnabled(false) }

        #expect(rig.desktop.sets.last?.file == file)
        try await Self.settle()
        #expect(fresh.asks.isEmpty, "a launch before the interval asked for a picture")
    }

    @Test("A launch with no stored time, or one at least thirty minutes old, changes the display")
    func launchDue() async throws {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let never = rig.make()
        never.setEnabled(true)
        try await Self.firstPictureSet(rig)
        never.setEnabled(false)

        rig.clock.advance(minutes: 31)
        let fresh = Stub(.picture(Self.other, "image/heic"))
        let relaunched = rig.make(source: fresh)
        relaunched.setEnabled(true)
        defer { relaunched.setEnabled(false) }
        try await Self.until({ fresh.asks.count == 1 }, "a picture for a display that was due")
    }

    // MARK: - Events

    @Test("Waking before a display is due changes nothing; waking after it changes that display")
    func waking() async throws {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let wallpaper = rig.make()
        wallpaper.setEnabled(true)
        defer { wallpaper.setEnabled(false) }
        try await Self.firstPictureSet(rig)

        rig.clock.advance(minutes: 10)
        wallpaper.woke()
        try await Self.settle()
        #expect(rig.source.asks.count == 1, "a wake before the interval changed the picture")

        rig.clock.advance(minutes: 21)
        wallpaper.woke()
        try await Self.until({ rig.source.asks.count == 2 }, "a change after waking past the interval")
    }

    @Test("Reapplying sets the same files without asking; a display with no picture is asked for one")
    func reapplying() async throws {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let wallpaper = rig.make()
        wallpaper.setEnabled(true)
        defer { wallpaper.setEnabled(false) }
        try await Self.until({ rig.desktop.sets.count == 1 }, "a first picture")
        let file = try #require(rig.desktop.sets.first).file

        rig.screens.list = [Self.big, Self.small]
        wallpaper.reapply(because: "the displays changed")

        #expect(rig.desktop.sets.dropFirst().first?.file == file, "A's file was not put back")
        try await Self.until(
            { rig.source.asks.map(\.displayID) == ["A", "B"] }, "a picture for the new display")
    }

    // MARK: - The checkbox

    @Test("The checkbox is off until ticked, and stays as it was left")
    func checkboxPersists() {
        let rig = Rig(.empty, displays: [])
        #expect(!rig.make().isEnabled)

        let ticked = rig.make()
        ticked.setEnabled(true)
        ticked.setEnabled(false)
        ticked.setEnabled(true)
        #expect(rig.make().isEnabled)
        ticked.setEnabled(false)
        #expect(!rig.make().isEnabled)
    }

    @Test("Unticking stops the asking and sets nothing; ticking again changes only what is due")
    func untickAndTick() async throws {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let wallpaper = rig.make()
        wallpaper.setEnabled(true)
        try await Self.firstPictureSet(rig)
        let file = try #require(rig.desktop.sets.first).file

        wallpaper.setEnabled(false)
        rig.clock.advance(minutes: 31)
        wallpaper.woke()
        wallpaper.reapply(because: "the Space changed")
        try await Self.settle()
        #expect(rig.source.asks.count == 1, "an unticked wallpaper asked")
        #expect(rig.desktop.sets.count == 1, "an unticked wallpaper set the desktop")

        rig.clock.advance(minutes: -21)
        wallpaper.setEnabled(true)
        defer { wallpaper.setEnabled(false) }
        #expect(rig.desktop.sets.last?.file == file, "ticking again did not put the file back")
        try await Self.settle()
        #expect(rig.source.asks.count == 1, "ticking again changed a display that was not due")
    }

    // MARK: - The interval is a preference

    /// Syd, 2026-09-10: "60 seconds for now … this should be part of the
    /// wallpaper preferences."
    @Test("The interval is sixty seconds when nothing has set it")
    func intervalDefault() {
        let rig = Rig(.empty, displays: [])
        UserDefaults(suiteName: rig.suite)!.removeObject(forKey: "intervalSeconds")
        #expect(rig.make().interval == .seconds(60))
    }

    @Test("A set interval is used, and a changed one applies without a restart")
    func intervalIsReadThrough() async {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let wallpaper = rig.make()
        _ = await wallpaper.round()
        rig.clock.advance(minutes: 2)
        #expect(!wallpaper.isDue("A"), "thirty minutes were not honoured")

        UserDefaults(suiteName: rig.suite)!.set(60, forKey: "intervalSeconds")
        #expect(wallpaper.isDue("A"), "a shorter interval waited for a restart")
    }

    @Test("Nonsense from defaults write is ignored or clamped, never accepted")
    func intervalIsValidated() {
        let rig = Rig(.empty, displays: [])
        let defaults = UserDefaults(suiteName: rig.suite)!
        let wallpaper = rig.make()

        defaults.set("soon", forKey: "intervalSeconds")
        #expect(wallpaper.interval == .seconds(60))
        defaults.set(0, forKey: "intervalSeconds")
        #expect(wallpaper.interval == .seconds(10))
        defaults.set(-5, forKey: "intervalSeconds")
        #expect(wallpaper.interval == .seconds(10))
        defaults.set(1e12, forKey: "intervalSeconds")
        #expect(wallpaper.interval == .seconds(7 * 24 * 60 * 60))
    }

    @Test("The loop looks again at least every thirty seconds, so a changed interval is noticed")
    func recheckCapsTheSleep() async {
        let rig = Rig(.picture(Self.heic, "image/heic"), displays: [Self.big])
        let wait = await rig.make(recheck: Wallpaper.defaultRecheck).round()
        #expect(wait == .seconds(30))
    }

    // MARK: - Where it lives

    @Test("Each deployment has its own domain and directory, and neither is the agent's")
    func home() {
        let user = URL(filePath: "/Users/someone")
        let development = WallpaperHome(deployment: .development, home: user)
        let production = WallpaperHome(deployment: .production, home: user)

        #expect(development.domain == "com.sydpolk.photogoround.wallpaper.dev")
        #expect(production.domain == "com.sydpolk.photogoround.wallpaper.prod")
        #expect(development.directory.path(percentEncoded: false)
            == "/Users/someone/Library/Application Support/com.sydpolk.photogoround.wallpaper.dev")
        #expect(production.directory.path(percentEncoded: false)
            == "/Users/someone/Library/Application Support/com.sydpolk.photogoround.wallpaper.prod")
        #expect(!development.directory.path(percentEncoded: false).contains("Containers"))
    }
}
