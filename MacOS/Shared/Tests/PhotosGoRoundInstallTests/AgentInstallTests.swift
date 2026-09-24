import Foundation
import Testing

@testable import PhotosGoRoundInstall

/// The agent install's judgement and the shape of the job it writes.
///
/// What is not here, and cannot be: that `launchctl bootstrap` actually starts
/// the job. That stays a hand check on a real Mac.
@Suite("What installing the agent would do")
struct AgentInstallTests {

    private let agents = URL(filePath: "/tmp/pgr-test/LaunchAgents")
    private let bundle = URL(filePath: "/build/Products/Debug/Photos-Go-Round Server.app")
    private var binary: URL { bundle.appending(path: "Contents/MacOS/Photos-Go-Round Server") }

    private func surroundings(
        bundleExists: Bool = true,
        executable: Bool = true,
        label: String? = "com.sydpolk.photosgoround.server.debug",
        loaded: Bool = false,
        running: [AgentInstall.ForeignAgent] = []
    ) -> AgentInstall.Surroundings {
        AgentInstall.Surroundings(
            directoryExists: { _ in bundleExists },
            isExecutable: { _ in executable },
            labelInBundle: { _ in label },
            isJobLoaded: { _ in loaded },
            runningAgents: { running }
        )
    }

    /// **The label is the bundle's own.** launchd allows one job per label per
    /// user, so a constant would mean a Debug install boots out a Release one
    /// and neither can tell it happened.
    @Test(
        "The label is read from the bundle, not assumed",
        arguments: [
            "com.sydpolk.photosgoround.server",
            "com.sydpolk.photosgoround.server.debug",
            "com.sydpolk.photosgoround.server.claude",
        ])
    func labelComesFromTheBundle(_ label: String) throws {
        let plan = try AgentInstall.plan(
            for: bundle, launchAgents: agents, surroundings: surroundings(label: label))
        #expect(plan.label == label)
        #expect(plan.plist == agents.appending(path: "\(label).plist"))
    }

    /// A bundle built before the label moved into `Info.plist` is refused with
    /// the remedy, rather than installed under a guess.
    @Test("A bundle with no label is refused, and says to rebuild")
    func missingLabelIsRefused() {
        #expect(throws: AgentInstall.Failure.noLabel(bundle)) {
            try AgentInstall.plan(
                for: bundle, launchAgents: agents, surroundings: surroundings(label: nil))
        }
        #expect(
            String(describing: AgentInstall.Failure.noLabel(bundle)).contains("rebuild it"))
    }

    @Test("A missing bundle and a missing executable are told apart")
    func missingThings() {
        #expect(throws: AgentInstall.Failure.noBundle(bundle)) {
            try AgentInstall.plan(
                for: bundle, launchAgents: agents, surroundings: surroundings(bundleExists: false))
        }
        #expect(throws: AgentInstall.Failure.noExecutable(binary)) {
            try AgentInstall.plan(
                for: bundle, launchAgents: agents, surroundings: surroundings(executable: false))
        }
    }

    /// **An agent the owner started is reported, never killed.** Syd,
    /// 2026-09-15, killed his by hand rather than have a build do it. The job's
    /// own process is not a foreigner, because the install is about to restart
    /// it anyway.
    @Test("The job's own process is not mistaken for somebody else's")
    func ownProcessIsNotForeign() throws {
        let own = AgentInstall.ForeignAgent(pid: 101, path: binary.path(percentEncoded: false))
        let theirs = AgentInstall.ForeignAgent(pid: 202, path: "/tmp/hand-built/Photos-Go-Round Server")
        let plan = try AgentInstall.plan(
            for: bundle, launchAgents: agents,
            surroundings: surroundings(running: [own, theirs]))
        #expect(plan.foreignAgents == [theirs])
        #expect(plan.describedSteps.contains { $0.contains("report pid 202") })
        #expect(plan.describedSteps.contains { $0.contains("leave it alone") })
        #expect(!plan.describedSteps.contains { $0.contains("101") })
    }

    @Test("A loaded job is known to need booting out first")
    func bootoutIsPlanned() throws {
        let fresh = try AgentInstall.plan(
            for: bundle, launchAgents: agents, surroundings: surroundings(loaded: false))
        #expect(fresh.replacesLoadedJob == false)
        #expect(!fresh.describedSteps.contains { $0.contains("boot out") })

        let over = try AgentInstall.plan(
            for: bundle, launchAgents: agents, surroundings: surroundings(loaded: true))
        #expect(over.replacesLoadedJob)
        #expect(over.describedSteps.contains { $0.contains("boot out") })
    }

    /// A clean build directory takes the agent with it, so an install from one
    /// says so rather than leaving it to be discovered.
    @Test("An install pointing into a build directory knows that it does")
    func buildDirectoryIsNoticed() throws {
        let derived = try AgentInstall.plan(
            for: URL(filePath: "/Users/x/Library/Developer/Xcode/DerivedData/P-abc/Build/Products/Debug/Photos-Go-Round Server.app"),
            launchAgents: agents, surroundings: surroundings())
        #expect(derived.pointsIntoBuildDirectory)

        let installed = try AgentInstall.plan(
            for: URL(filePath: "/Applications/Photos-Go-Round Server.app"),
            launchAgents: agents, surroundings: surroundings())
        #expect(installed.pointsIntoBuildDirectory == false)
    }

    /// **`bootout` returns before the job is gone**, measured 2026-09-16, and a
    /// bootstrap into the gap fails with "Operation already in progress". A job
    /// that will not leave is reported rather than waited on for ever.
    @Test("Waiting for launchd gives up rather than hanging")
    func bootoutWaitIsBounded() throws {
        var asked = 0
        let never = try AgentInstall.waitForLaunchdToForget(
            "stuck", within: .milliseconds(120), polling: .milliseconds(20)
        ) { _ in
            asked += 1
            return true
        }
        #expect(never == false)
        #expect(asked > 1, "it should have polled rather than asked once")

        let gone = try AgentInstall.waitForLaunchdToForget(
            "fine", within: .milliseconds(120), polling: .milliseconds(20)) { _ in false }
        #expect(gone)

        // The bound the install actually uses, past the job's five-second exit
        // timeout. Measured 2026-09-16; see `bootoutTimeout`.
        #expect(AgentInstall.bootoutTimeout == .seconds(10))
    }

    /// The plist is a value now, so its shape is checkable. Every field here was
    /// argued for somewhere; `ProcessType` most of all.
    @Test("The job description carries exactly the fields launchd is given")
    func jobDescriptionShape() throws {
        let job = JobDescription(
            label: "com.sydpolk.photosgoround.server.debug", program: binary,
            deployment: .development)
        let decoded =
            try PropertyListSerialization.propertyList(from: job.encodedPlist(), format: nil)
            as? [String: Any]
        let values = try #require(decoded)

        #expect(values["Label"] as? String == "com.sydpolk.photosgoround.server.debug")
        #expect(values["ProgramArguments"] as? [String] == [binary.path(percentEncoded: false)])
        #expect(values["RunAtLoad"] as? Bool == true)
        #expect((values["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false)
        // Background throttles disk I/O, and this agent reads disk to answer a
        // person waiting on a picture. Measured 2026-09-17.
        #expect(values["ProcessType"] as? String == "Adaptive")
        #expect(values["ProcessType"] as? String != "Background")
        // Filed under the app in Login Items rather than under the signing
        // certificate's name. Checked 2026-09-23 with `sfltool dumpbtm`.
        #expect(values["AssociatedBundleIdentifiers"] as? [String] == ["com.sydpolk.photosgoround"])
    }

    /// A production job says so, though a Release agent is production without
    /// it since 2026-09-24; a Debug or Claude job must not ask for it.
    @Test("Only a production job passes --prod")
    func productionJobPassesProd() {
        let path = binary.path(percentEncoded: false)
        let production = JobDescription(
            label: "com.sydpolk.photosgoround.server", program: binary, deployment: .production)
        let development = JobDescription(
            label: "com.sydpolk.photosgoround.server.debug", program: binary, deployment: .development)

        #expect(production.programArguments == [path, "--prod"])
        #expect(development.programArguments == [path])
    }

    /// An installed plist from before the key existed is a different job, so
    /// the next app launch writes it again — which is how existing installs
    /// get the key.
    @Test("A plist without the app named is an older job description")
    func olderPlistIsReinstalled() throws {
        var older = JobDescription(label: "com.sydpolk.photosgoround.server", program: binary)
        older.associatedBundleIdentifiers = nil
        let decoded = try PropertyListDecoder().decode(
            JobDescription.self, from: older.encodedPlist())

        #expect(decoded.associatedBundleIdentifiers == nil)
        #expect(decoded != JobDescription(label: "com.sydpolk.photosgoround.server", program: binary))
    }
}
