import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundInstall

/// Finding every configuration's installed pieces, and only those.
///
/// **The failure this guards against is a partial uninstall.** Three
/// configurations install under three sets of names, and a command that knew
/// one would leave two running while reporting success.
@Suite("What uninstalling would remove")
struct UninstallTests {

    private let agents = URL(filePath: "/tmp/pgr-test/LaunchAgents")
    private let savers = URL(filePath: "/tmp/pgr-test/Screen Savers")

    private func surroundings(
        loaded: Set<String> = [],
        files: Set<String> = [],
        registered: [WallpaperInstall.Registration] = [],
        running: [AgentInstall.ForeignAgent] = []
    ) -> Uninstall.Surroundings {
        Uninstall.Surroundings(
            isJobLoaded: { loaded.contains($0) },
            fileExists: { files.contains($0.path(percentEncoded: false)) },
            registrations: { registered },
            runningAgents: { running })
    }

    /// **Three of everything, from `BuildVariant` rather than a second list.**
    @Test("Every configuration's agent is looked for, not just this build's")
    func everyAgentLabel() {
        let plan = Uninstall.plan(
            removing: [.agent], launchAgents: agents, screenSavers: savers,
            surroundings: surroundings())
        #expect(plan.agents.count == BuildVariant.allCases.count)
        #expect(Set(plan.agents.map(\.label)) == Set(BuildVariant.allCases.map(\.agentLabel)))
    }

    @Test("Every configuration's saver is looked for")
    func everySaverName() {
        let all = BuildVariant.allCases.map {
            savers.appending(path: "\($0.saverBundleName).saver").path(percentEncoded: false)
        }
        let plan = Uninstall.plan(
            removing: [.saver], launchAgents: agents, screenSavers: savers,
            surroundings: surroundings(files: Set(all)))
        #expect(plan.savers.count == BuildVariant.allCases.count)
    }

    @Test("Only what is actually there is reported")
    func onlyWhatIsPresent() {
        let debug = BuildVariant.debug
        let plan = Uninstall.plan(
            removing: Set(Uninstall.Part.allCases), launchAgents: agents, screenSavers: savers,
            surroundings: surroundings(
                loaded: [debug.agentLabel],
                files: [savers.appending(path: "\(debug.saverBundleName).saver")
                    .path(percentEncoded: false)]))
        #expect(plan.agents.filter(\.isPresent).map(\.label) == [debug.agentLabel])
        #expect(plan.savers.count == 1)
        #expect(plan.describedSteps.contains { $0.contains("boot out \(debug.agentLabel)") })
    }

    /// A plist left behind by a job that is no longer loaded still counts:
    /// launchd will load it again at the next login.
    @Test("A plist with no loaded job is still present")
    func orphanedPlistCounts() {
        let label = BuildVariant.release.agentLabel
        let plan = Uninstall.plan(
            removing: [.agent], launchAgents: agents, screenSavers: savers,
            surroundings: surroundings(
                files: [agents.appending(path: "\(label).plist").path(percentEncoded: false)]))
        let found = plan.agents.first { $0.label == label }
        #expect(found?.isPresent == true)
        #expect(found?.jobIsLoaded == false)
        #expect(plan.describedSteps.contains { $0.contains("remove") && $0.contains(label) })
    }

    /// Apple's wallpaper extensions share the extension point and are never ours
    /// to unregister.
    @Test("Only Photo-Go-Round registrations are taken")
    func onlyOurRegistrations() {
        let ours = WallpaperInstall.Registration(
            identifier: "com.sydpolk.photogoround.wallpaper.debug.extension", path: "/ours.appex")
        let apple = WallpaperInstall.Registration(
            identifier: "com.apple.wallpaper.extension.image", path: "/system.appex")
        let plan = Uninstall.plan(
            removing: [.wallpaper], launchAgents: agents, screenSavers: savers,
            surroundings: surroundings(registered: [apple, ours]))
        #expect(plan.registrations == [ours])
    }

    @Test("Naming one part leaves the others entirely alone", arguments: Uninstall.Part.allCases)
    func partsAreIndependent(_ part: Uninstall.Part) {
        let plan = Uninstall.plan(
            removing: [part], launchAgents: agents, screenSavers: savers,
            surroundings: surroundings(
                loaded: Set(BuildVariant.allCases.map(\.agentLabel)),
                files: Set(BuildVariant.allCases.map {
                    savers.appending(path: "\($0.saverBundleName).saver").path(percentEncoded: false)
                }),
                registered: [.init(identifier: "com.sydpolk.photogoround.wallpaper.extension", path: "/x.appex")]))
        #expect(plan.agents.isEmpty == (part != .agent))
        #expect(plan.savers.isEmpty == (part != .saver))
        #expect(plan.registrations.isEmpty == (part != .wallpaper))
    }

    /// Nothing about a library, a cache or a preference domain appears anywhere
    /// in what an uninstall would do. `Scripts/scrub-dev.sh` is what clears
    /// those, and deliberately cannot reach production.
    @Test("An uninstall never mentions the library, the cache or preferences")
    func neverTouchesData() {
        let plan = Uninstall.plan(
            removing: Set(Uninstall.Part.allCases), launchAgents: agents, screenSavers: savers,
            surroundings: surroundings(loaded: Set(BuildVariant.allCases.map(\.agentLabel))))
        let said = plan.describedSteps.joined(separator: " ").lowercased()
        for forbidden in ["containers", "caches", "photogoround.sqlite", "preferences"] {
            #expect(!said.contains(forbidden), "an uninstall should never name \(forbidden)")
        }
    }
}
