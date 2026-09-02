import Foundation
import Testing

/// Throwaway preference domains that leave nothing behind.
///
/// Compiled into every test target rather than shared through a module, because
/// each target is its own process and what is being managed here — a directory
/// and an exit hook — belongs to a process.
enum ScratchPreferences {

    /// Every scratch domain's file name begins with this, so a log line or a
    /// stray file says what it is. The real domains, `com.sydpolk.photogoround`
    /// and `.dev`, cannot match it, which is why it ends in `.tests.` rather
    /// than stopping at the bundle identifier.
    static let prefix = "com.sydpolk.photogoround.tests."

    /// Where a scratch domain would land if it were a dotted name: the
    /// directory `cfprefsd` owns, and the one this file exists to keep clean.
    static let homePreferences = URL.homeDirectory.appending(path: "Library/Preferences")

    /// One directory per process, holding every scratch suite it makes, removed
    /// when the process exits.
    ///
    /// **A suite is named by a path, not a reverse-DNS domain.** `CFPreferences`
    /// has always accepted one — `defaults read /path/to/file` is the same
    /// feature — and keeps the domain at `<path>.plist` rather than under
    /// `~/Library/Preferences`. That is the whole fix. A dotted domain lives in
    /// a directory `cfprefsd` owns and writes on its own schedule, including
    /// after the process is gone; measured on this machine, one came back after
    /// `removeItem` and after `removePersistentDomain` alike, and the sweeps
    /// built to chase them were still losing. A path domain lives in a
    /// directory *this process* owns, and removing that directory is a teardown
    /// the daemon does not undo: forty domains with writes still in flight,
    /// half of them torn down with `removePersistentDomain` for good measure,
    /// their root removed from `atexit` — nothing came back in two minutes.
    ///
    /// One root rather than one directory per suite so that a suite made
    /// through `scratchSuite(_:)`, whose caller never sees a name to discard,
    /// is collected all the same.
    static let root: URL = {
        let url = URL.temporaryDirectory.appending(
            path: "pgr-prefs-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: ScratchPreferences.root) }
        return url
    }()

    /// Dotted scratch domains in `~/Library/Preferences` right now — the
    /// files this design makes impossible, so any that exist were made by a
    /// test that went around it.
    static func strays() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: homePreferences, includingPropertiesForKeys: nil)) ?? []
        return files
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix(prefix) || $0.hasPrefix("pgr.") }
            .sorted()
    }

    /// What was already there the first time this process looked.
    ///
    /// Read once, and `scratchSuiteName` touches it before creating anything,
    /// so the snapshot is taken before this run can contribute to it. Whatever
    /// it holds was left by an earlier run.
    static let inherited: [String] = strays()
}

/// A throwaway `UserDefaults` suite name: a path under `ScratchPreferences.root`,
/// in a directory of its own so `discardScratchSuite` can take it early.
///
/// Going through here is what keeps a new test from inventing its own dotted
/// namespace — several used to use a bare `pgr.` — and writing a plist into
/// `~/Library/Preferences` that nothing ever collects.
func scratchSuiteName(_ label: String) -> String {
    _ = ScratchPreferences.inherited
    let directory = ScratchPreferences.root.appending(path: "\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "\(ScratchPreferences.prefix)\(label)")
        .path(percentEncoded: false)
}

func scratchSuite(_ label: String) -> UserDefaults {
    UserDefaults(suiteName: scratchSuiteName(label))!
}

/// Removes a scratch suite's directory now rather than at exit.
///
/// Optional — the root goes at exit regardless — but a long run makes a lot of
/// these, and a test that holds a name may as well return the space. Nothing
/// else belongs here: `removePersistentDomain` and `synchronize` are writes
/// through the daemon, and the daemon is exactly what this design keeps out of
/// the teardown.
func discardScratchSuite(_ name: String) {
    try? FileManager.default.removeItem(at: URL(filePath: name).deletingLastPathComponent())
}

/// Fails when an earlier run left a dotted scratch domain in
/// `~/Library/Preferences`.
///
/// A path domain cannot land there, so a file that did was made by a test that
/// named its own suite instead of asking `scratchSuiteName` for one. It is
/// checked at the start of a run rather than the end because that is when the
/// daemon has finished writing whatever the last run asked for.
@Suite("Scratch preference hygiene")
struct ScratchPreferenceHygieneTests {

    @Test("No scratch preference file survived an earlier run")
    func nothingInherited() {
        #expect(
            ScratchPreferences.inherited.isEmpty,
            """
            \(ScratchPreferences.inherited.count) scratch preference file(s) \
            survived an earlier test run:
            \(ScratchPreferences.inherited.map { "  \($0)" }.joined(separator: "\n"))

            A test built a dotted suite by hand instead of calling scratchSuite(_:) \
            or scratchSuiteName(_:). Find that test; then `defaults delete` each \
            domain above to get back to green.
            """
        )
    }

    @Test("A scratch suite lives under the process root, not in ~/Library/Preferences")
    func suitesLiveUnderTheRoot() {
        let name = scratchSuiteName("hygiene")
        defer { discardScratchSuite(name) }
        let defaults = UserDefaults(suiteName: name)!
        defaults.set("v", forKey: "k")
        #expect(UserDefaults(suiteName: name)!.string(forKey: "k") == "v")
        #expect(name.hasPrefix(ScratchPreferences.root.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: name + ".plist"))
        #expect(!ScratchPreferences.strays().contains { $0.contains("hygiene") })
    }
}
