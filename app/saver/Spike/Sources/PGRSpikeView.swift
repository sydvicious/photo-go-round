import AppKit
import Foundation
import OSLog
import ScreenSaver

/// The Phase 1 spike: a `.saver` that draws no photographs and answers two
/// questions about the sandbox it was loaded into.
///
/// **It links nothing.** Not `PhotoGoRoundDisplay`, not the kit, not the agent
/// API — a stub that fails to load tells you nothing if it had four chances to
/// fail. Everything here is Foundation and `ScreenSaver`, so a failure is the
/// host refusing *us* rather than refusing something we brought.
///
/// The questions, in the order they matter:
///
/// 1. **Can it reach the agent at all?** `legacyScreenSaver`'s entitlements
///    grant `com.apple.security.network.client`, so this should work; the point
///    of asking anyway is that entitlements describe the container a process was
///    signed into rather than the profile it ends up running under.
/// 2. **Can it find the agent?** The port is published into a preference domain
///    owned by another application, and there is no `shared-preference-read`
///    exception in the host's grant. This is the one with no prior.
///
/// Both are asked with the port pinned, so that a failure of one is never read
/// as a failure of the other. See `Screensaver Plan.md`.
@objc(PGRSpikeView)
public final class PGRSpikeView: ScreenSaverView {

    /// The agent this spike talks to, started with `--port 9000`. Pinned rather
    /// than discovered *on purpose*: discovery is question two, and a spike that
    /// needed it to answer question one could only ever fail at both together.
    private static let pinnedPort = 9000

    /// The development domain, which is what the window talks to. A saver that
    /// can read this can read the production one.
    private static let preferenceDomain = "com.sydpolk.photogoround.dev"

    /// Same subsystem and category as `Log.saver`, spelled out because this
    /// bundle deliberately links nothing.
    private static let log = Logger(subsystem: "com.sydpolk.photogoround", category: "saver")

    /// What was found, drawn on the glass as well as logged.
    ///
    /// **Both, and that is not redundancy.** The log is the diagnostic and holds
    /// everything; the screen answers "did the bundle load at all" in the time it
    /// takes to look, which is the failure mode `PLAN.md` warns is silent and
    /// maximally unhelpful.
    private var lines: [String] = ["Photo-Go-Round saver spike", ""]
    private var checked = false

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 4.0
    }

    /// Required because the class is instantiated through the Objective-C
    /// runtime. One of the three configuration traps that make a Swift `.saver`
    /// silently not appear — see `PLAN.md`, *Swift everywhere*.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 4.0
    }

    public override var hasConfigureSheet: Bool { false }
    public override var configureSheet: NSWindow? { nil }

    public override func startAnimation() {
        super.startAnimation()
        // The preview instance runs the checks too. It is a second process-side
        // instantiation with the same sandbox, and if the two ever disagree that
        // is worth knowing before Phase 4 builds a thumbnail on the assumption
        // they do not.
        guard !checked else { return }
        checked = true
        Task { @MainActor in await runChecks() }
    }

    // MARK: - The checks

    @MainActor
    private func runChecks() async {
        say("--- where we are ---")
        say("preview: \(isPreview)")
        say("pid: \(getpid())  uid: \(getuid())")
        // Paths are `.public` here and nowhere else in this project. The
        // convention keeps them private; a spike whose entire purpose is to find
        // out which paths are reachable cannot report `<private>` and be of any
        // use. It ships once and is deleted.
        say("bundle: \(Bundle(for: Self.self).bundlePath)")
        say("NSHomeDirectory: \(NSHomeDirectory())")
        say("real home: \(Self.realHome())")
        say("sandboxed: \(NSHomeDirectory() != Self.realHome())")

        say("")
        say("--- Q2: finding the port ---")
        let viaPreferences = checkPreferenceRead()
        let viaFile = checkPlistRead()

        say("")
        say("--- Q1: reaching the agent, port \(Self.pinnedPort) pinned ---")
        // Both spellings, because they are not the same question. `localhost`
        // resolves through libinfo, which reaches `mDNSResponder` over a Mach
        // lookup the host's exception list does not name — so it can fail where
        // a literal address succeeds. `PictureClient` builds its URL with
        // `localhost` today, which would make that a bug in shipping code rather
        // than a curiosity.
        await request(host: "127.0.0.1", port: Self.pinnedPort)
        await request(host: "localhost", port: Self.pinnedPort)

        // Only worth asking when discovery produced something and it is not the
        // pinned one; otherwise it repeats a request just made.
        if let discovered = viaPreferences ?? viaFile, discovered != Self.pinnedPort {
            say("")
            say("--- the discovered port, \(discovered) ---")
            await request(host: "127.0.0.1", port: discovered)
        }

        say("")
        say("--- done ---")
    }

    /// Question two, the way every client asks it today: `UserDefaults` through
    /// `cfprefsd`, which arbitrates per domain and has no exception for ours.
    private func checkPreferenceRead() -> Int? {
        guard let defaults = UserDefaults(suiteName: Self.preferenceDomain) else {
            say("cfprefs: UserDefaults(suiteName:) returned nil")
            return nil
        }
        guard defaults.object(forKey: "servicePort") != nil else {
            say("cfprefs: opened the suite, no servicePort in it")
            return nil
        }
        let port = defaults.integer(forKey: "servicePort")
        say("cfprefs: servicePort = \(port)")
        return port > 0 ? port : nil
    }

    /// The fallback, and the reason the whole-filesystem read exception matters:
    /// an ordinary `open(2)` on the plist rather than a Mach round trip to the
    /// preferences daemon.
    ///
    /// **The path is built from the real home, not `NSHomeDirectory()`,** which
    /// inside the sandbox names the host's container and holds nothing of ours.
    private func checkPlistRead() -> Int? {
        let path = "\(Self.realHome())/Library/Preferences/\(Self.preferenceDomain).plist"
        say("plist: \(path)")
        guard let data = FileManager.default.contents(atPath: path) else {
            say("plist: unreadable")
            return nil
        }
        say("plist: read \(data.count) bytes")
        guard
            let any = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let dictionary = any as? [String: Any]
        else {
            say("plist: would not parse")
            return nil
        }
        guard let port = dictionary["servicePort"] as? Int else {
            say("plist: parsed \(dictionary.count) keys, no servicePort")
            return nil
        }
        say("plist: servicePort = \(port)")
        return port
    }

    /// Question one. The same shape of request `PictureClient` makes, without
    /// its deadline or its failure taxonomy — this reports what happened rather
    /// than deciding what it means.
    private func request(host: String, port: Int) async {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/v1/next"
        components.queryItems = [
            URLQueryItem(name: "consumer", value: "saver-spike"),
            URLQueryItem(name: "w", value: "1920"),
            URLQueryItem(name: "h", value: "1080"),
        ]
        guard let url = components.url else {
            say("\(host): could not build a URL")
            return
        }

        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                say("\(host): answered, and not with HTTP")
                return
            }
            let card = http.value(forHTTPHeaderField: "X-PGR-Card") ?? "-"
            say("\(host): \(http.statusCode), \(data.count) bytes, card \(card), \(elapsed) ms")
        } catch {
            say("\(host): \(error.localizedDescription)")
        }
    }

    // MARK: - Saying it

    /// The true home. `NSHomeDirectory()` is rewritten to the container inside a
    /// sandbox; `getpwuid` reads the password database and is not.
    private static func realHome() -> String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return NSHomeDirectory()
        }
        return String(cString: directory)
    }

    @MainActor
    private func say(_ line: String) {
        Self.log.notice("saver: \(line, privacy: .public)")
        lines.append(line)
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()

        let size = max(11.0, min(20.0, bounds.height / 46))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        var y = bounds.height - size * 3
        for line in lines {
            (line as NSString).draw(
                at: NSPoint(x: size * 2, y: y), withAttributes: attributes)
            y -= size * 1.4
            if y < size { break }
        }
    }

    /// Nothing per-frame. The pan will be a layer animation for the reason
    /// `PLAN.md` gives — per-frame drawing stutters exactly when somebody would
    /// notice — and there is nothing to animate here in any case.
    public override func animateOneFrame() {}
}
