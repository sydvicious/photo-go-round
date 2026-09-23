import Foundation
import PhotosGoRoundAgentAPI

/// Installing the agent as a per-user LaunchAgent: what would happen, and then
/// it happening.
///
/// **Full install, decided 2026-09-15.** Syd chose it over building the bundle
/// alone and over writing the plist without starting it, and that is what ended
/// the "three ways to run the agent" confusion: after this, the job is the
/// agent.
///
/// **`~/Library/LaunchAgents`, per user.** Syd, 2026-09-10: "whatever launchctl
/// needs should be put into ~/Library/LaunchAgents so multiple users don't
/// clobber each other."
///
/// Translated from `Scripts/install-agent.sh`, 2026-09-19, which is deleted.
/// `Plans/Xcode - Separate Build and Run.md`, Phase 3.
public enum AgentInstall {

    /// The executable inside the bundle. Not the product name: the bundle is
    /// `Photos-Go-Round Server.app` and the binary in it is `photogoroundd`.
    public static let executableName = "photogoroundd"

    /// The key each configuration's `Info.plist` carries, holding the label
    /// launchd will know this build by.
    public static let labelKey = "PGRLaunchAgentLabel"

    /// How long to wait for launchd to finish removing a job.
    ///
    /// **`bootout` returns before the job is gone.** Measured 2026-09-16: a
    /// bootstrap at 13:29:11.409 failed with "37: Operation already in
    /// progress" while launchd logged "removing service" for the old job at
    /// .417, and Xcode showed "Bootstrap failed: 5: Input/output error" with the
    /// agent left not running at all. Ten seconds is past the job's five-second
    /// exit timeout, so a job that will not leave is reported rather than waited
    /// on for ever.
    public static let bootoutTimeout = Duration.seconds(10)
    static let bootoutPoll = Duration.milliseconds(100)

    /// What an install would do.
    public struct Plan: Equatable, Sendable {
        public var bundle: URL
        /// The binary the job will run.
        public var binary: URL
        /// What launchd will know it by — this build's own, never a constant.
        public var label: String
        /// Where the job description goes.
        public var plist: URL
        /// Whether a job of this label is already loaded and would be booted out.
        public var replacesLoadedJob: Bool
        /// Agents running outside launchd, which hold the port and are **not**
        /// this install's to stop.
        public var foreignAgents: [ForeignAgent]
        /// Whether the binary sits in a build directory, which is right for
        /// development and wrong for anything left running.
        public var pointsIntoBuildDirectory: Bool

        public var describedSteps: [String] {
            var steps: [String] = []
            for other in foreignAgents {
                steps.append("report pid \(other.pid) — \(other.path) — and leave it alone")
            }
            if replacesLoadedJob { steps.append("boot out \(label) and wait for launchd to forget it") }
            steps.append("write \(plist.path(percentEncoded: false))")
            steps.append("bootstrap \(label) running \(binary.path(percentEncoded: false))")
            return steps
        }
    }

    /// An agent somebody started themselves.
    ///
    /// **It is reported, never killed.** Syd, 2026-09-15, killed his by hand
    /// rather than have a build do it: stopping something the owner started is
    /// the owner's call. The job simply cannot bind until it goes.
    public struct ForeignAgent: Equatable, Sendable {
        public var pid: Int32
        public var path: String
        public init(pid: Int32, path: String) {
            self.pid = pid
            self.path = path
        }
    }

    /// What the plan needs to know about the machine.
    public struct Surroundings: Sendable {
        public var directoryExists: @Sendable (URL) -> Bool
        public var isExecutable: @Sendable (URL) -> Bool
        public var labelInBundle: @Sendable (URL) -> String?
        public var isJobLoaded: @Sendable (String) -> Bool
        public var runningAgents: @Sendable () -> [ForeignAgent]

        public init(
            directoryExists: @escaping @Sendable (URL) -> Bool,
            isExecutable: @escaping @Sendable (URL) -> Bool,
            labelInBundle: @escaping @Sendable (URL) -> String?,
            isJobLoaded: @escaping @Sendable (String) -> Bool,
            runningAgents: @escaping @Sendable () -> [ForeignAgent]
        ) {
            self.directoryExists = directoryExists
            self.isExecutable = isExecutable
            self.labelInBundle = labelInBundle
            self.isJobLoaded = isJobLoaded
            self.runningAgents = runningAgents
        }

        public static let live = Surroundings(
            directoryExists: { url in
                var isDirectory: ObjCBool = false
                let there = FileManager.default.fileExists(
                    atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
                return there && isDirectory.boolValue
            },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) },
            labelInBundle: { bundle in
                let plist = bundle.appending(path: "Contents/Info.plist")
                guard let data = try? Data(contentsOf: plist),
                    let values = try? PropertyListSerialization.propertyList(
                        from: data, format: nil) as? [String: Any],
                    let label = values[labelKey] as? String, !label.isEmpty
                else { return nil }
                return label
            },
            isJobLoaded: { label in Launchctl.isLoaded(label) },
            runningAgents: { Launchctl.agentsOutsideLaunchd(named: executableName) }
        )
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noBundle(URL)
        case noExecutable(URL)
        case noLabel(URL)
        case stillLoaded(String)
        case didNotBootstrap(String)
        case didNotRestart(String)
        case notInstalled(String)

        public var description: String {
            switch self {
            case .noBundle(let url):
                "no bundle at \(url.path(percentEncoded: false))"
            case .noExecutable(let url):
                "no executable at \(url.path(percentEncoded: false))"
            case .noLabel(let url):
                """
                \(url.lastPathComponent) carries no \(labelKey)
                  it was built before the label moved into the bundle; rebuild it
                """
            case .stillLoaded(let label):
                "\(label) is still loaded ten seconds after bootout"
            case .didNotBootstrap(let label):
                "\(label) did not bootstrap"
            case .didNotRestart(let label):
                "\(label) did not restart"
            case .notInstalled(let label):
                "\(label) is not installed: no plist in ~/Library/LaunchAgents"
            }
        }
    }

    public static func plan(
        for bundle: URL,
        launchAgents: URL = URL.homeDirectory.appending(path: "Library/LaunchAgents"),
        surroundings: Surroundings = .live
    ) throws -> Plan {
        guard surroundings.directoryExists(bundle) else { throw Failure.noBundle(bundle) }
        let binary = bundle.appending(path: "Contents/MacOS/\(executableName)")
        guard surroundings.isExecutable(binary) else { throw Failure.noExecutable(binary) }
        guard let label = surroundings.labelInBundle(bundle) else { throw Failure.noLabel(bundle) }

        let path = binary.path(percentEncoded: false)
        return Plan(
            bundle: bundle,
            binary: binary,
            label: label,
            plist: launchAgents.appending(path: "\(label).plist"),
            replacesLoadedJob: surroundings.isJobLoaded(label),
            // Anything not running from this very binary is somebody else's.
            foreignAgents: surroundings.runningAgents().filter { $0.path != path },
            pointsIntoBuildDirectory: path.contains("/DerivedData/") || path.contains("/.build/")
        )
    }

    /// What is installed now, as far as deciding whether it is current needs.
    public struct Installed: Sendable {
        /// The job description at this path, or nil when there is none.
        public var job: @Sendable (URL) -> JobDescription?
        public var isJobLoaded: @Sendable (String) -> Bool

        public init(
            job: @escaping @Sendable (URL) -> JobDescription?,
            isJobLoaded: @escaping @Sendable (String) -> Bool
        ) {
            self.job = job
            self.isJobLoaded = isJobLoaded
        }

        public static let live = Installed(
            job: { plist in
                guard let data = try? Data(contentsOf: plist) else { return nil }
                return try? PropertyListDecoder().decode(JobDescription.self, from: data)
            },
            isJobLoaded: { Launchctl.isLoaded($0) }
        )
    }

    /// Whether this bundle's agent is the one installed.
    ///
    /// **Current when the job description is the one this bundle would write
    /// and launchd has it loaded.** Anything else is installed again: a
    /// different binary is another copy of the app, and anything else in the
    /// description is an older app's idea of the job.
    ///
    /// **Whether the running process is up to date is not asked**, because
    /// every launch restarts it. Syd, 2026-09-21: "yes, restart the agent on
    /// every app launch". An app replaced at the same path leaves the plist
    /// exactly right, and the restart is what puts the new binary to work.
    public static func standing(
        of bundle: URL,
        launchAgents: URL = URL.homeDirectory.appending(path: "Library/LaunchAgents"),
        surroundings: Surroundings = .live,
        installed: Installed = .live
    ) throws -> Standing {
        let plan = try plan(for: bundle, launchAgents: launchAgents, surroundings: surroundings)
        guard let job = installed.job(plan.plist) else { return .missing }

        let wanted = JobDescription(label: plan.label, program: plan.binary)
        if job != wanted {
            if job.programArguments != wanted.programArguments {
                return .differs("the job runs \(job.programArguments.first ?? "nothing")")
            }
            return .differs("the job description is an older one")
        }
        guard installed.isJobLoaded(plan.label) else { return .differs("the job is not loaded") }
        return .current
    }

    /// Starts an installed job: loads its plist if launchd has not, and starts
    /// it either way.
    @discardableResult
    public static func start(
        _ variant: BuildVariant,
        launchAgents: URL = URL.homeDirectory.appending(path: "Library/LaunchAgents")
    ) throws -> [String] {
        let label = variant.agentLabel
        let plist = launchAgents.appending(path: "\(label).plist")
        guard FileManager.default.fileExists(atPath: plist.path(percentEncoded: false)) else {
            throw Failure.notInstalled(label)
        }
        if !Launchctl.isLoaded(label) { Launchctl.bootstrap(plist) }
        guard Launchctl.kickstart(label) else { throw Failure.didNotRestart(label) }
        return ["\(label) started"]
    }

    /// Stops a job and unloads it, leaving its plist, so `start` can bring it
    /// back. **Unloaded rather than signalled**: `KeepAlive` restarts a job
    /// whose process is killed, so a kill is not a stop.
    @discardableResult
    public static func stop(_ variant: BuildVariant) throws -> [String] {
        let label = variant.agentLabel
        guard Launchctl.isLoaded(label) else { return ["\(label) was not running"] }
        Launchctl.bootout(label)
        if try waitForLaunchdToForget(label) == false { throw Failure.stillLoaded(label) }
        return ["\(label) stopped; its plist is still installed"]
    }

    /// Restarts an installed job: stops its process and starts it again.
    @discardableResult
    public static func restart(_ plan: Plan) throws -> [String] {
        guard Launchctl.kickstart(plan.label) else { throw Failure.didNotRestart(plan.label) }
        return ["\(plan.label) restarted", "  \(plan.binary.path(percentEncoded: false))"]
    }

    /// Performs a plan, returning what it did, a line at a time.
    @discardableResult
    public static func apply(_ plan: Plan) throws -> [String] {
        var done: [String] = []

        // **Reported, never killed**, and reported without overclaiming: since
        // 2026-09-19 each build variant binds its own port, so another agent
        // only contends for this job's if it was built in the same
        // configuration — and its path does not say which. Saying "it holds the
        // port this job wants" was true when there was one port and is a guess
        // now. `BuildVariant.swift`.
        for other in plan.foreignAgents {
            done.append("another agent is running, pid \(other.pid)")
            done.append("  \(other.path)")
            done.append("  Not this install's to stop. If it was built in this")
            done.append("  configuration it holds this job's port: kill \(other.pid)")
        }

        // Out first, so the plist is never rewritten under a running job.
        // Failing is ordinary: there may be no job yet.
        Launchctl.bootout(plan.label)
        if try waitForLaunchdToForget(plan.label) == false {
            throw Failure.stillLoaded(plan.label)
        }

        try JobDescription(label: plan.label, program: plan.binary).write(to: plan.plist)

        Launchctl.bootstrap(plan.plist)
        guard Launchctl.isLoaded(plan.label) else { throw Failure.didNotBootstrap(plan.label) }

        done.append("\(plan.label) bootstrapped")
        done.append("  \(plan.binary.path(percentEncoded: false))")
        done.append(
            "  log: /usr/bin/log stream --info --predicate 'subsystem == \"com.sydpolk.photosgoround\"'")
        if plan.pointsIntoBuildDirectory {
            done.append("  note — this job points into the build directory")
        }
        return done
    }

    /// Polls until launchd stops knowing the label, or the bound runs out.
    /// The bound is a parameter so a test can prove the give-up without waiting
    /// out the real ten seconds; nothing else passes one.
    static func waitForLaunchdToForget(
        _ label: String,
        within timeout: Duration = bootoutTimeout,
        polling interval: Duration = bootoutPoll,
        isLoaded: (String) -> Bool = Launchctl.isLoaded
    ) throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !isLoaded(label) { return true }
            Thread.sleep(forTimeInterval: Double(interval.components.attoseconds) / 1e18
                + Double(interval.components.seconds))
        }
        return !isLoaded(label)
    }
}
