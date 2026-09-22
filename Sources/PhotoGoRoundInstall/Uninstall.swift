import Foundation
import PhotoGoRoundAgentAPI

/// Taking Photo-Go-Round off a Mac: what is there, and then removing it.
///
/// **Three of everything.** Release, Debug and Claude each install under their
/// own label, saver name and extension identifier, so an uninstall that knew
/// only one name would leave the other two running. Those names come from
/// `BuildVariant` rather than being listed again here — which is the whole
/// point of Phase 5.
///
/// **It removes what was installed, not what was built.** Build directories,
/// the library, the cache and the preferences are left alone: uninstalling is
/// not the same as throwing away the photographs somebody chose.
/// `Scripts/scrub-dev.sh` is what clears development storage.
///
/// Translated from `Scripts/uninstall.sh`, 2026-09-19.
/// `Plans/Xcode - Separate Build and Run.md`, Phase 5.
public enum Uninstall {

    public enum Part: String, CaseIterable, Sendable {
        case agent, wallpaper, saver
    }

    /// One configuration's agent, and what of it is actually here.
    public struct InstalledAgent: Equatable, Sendable {
        public var label: String
        public var jobIsLoaded: Bool
        public var plist: URL
        public var plistExists: Bool
        public var isPresent: Bool { jobIsLoaded || plistExists }
    }

    public struct Plan: Equatable, Sendable {
        public var parts: Set<Part>
        public var agents: [InstalledAgent]
        public var foreignAgents: [AgentInstall.ForeignAgent]
        public var registrations: [WallpaperInstall.Registration]
        public var savers: [URL]
        /// Whose copies were looked for.
        public var variants: [BuildVariant] = BuildVariant.allCases

        /// "any configuration", or the one that was asked about.
        var whose: String {
            variants.count == 1 ? "the \(variants[0].description)" : "any configuration"
        }

        public var describedSteps: [String] {
            var steps: [String] = []
            if parts.contains(.agent) {
                let present = agents.filter(\.isPresent)
                if present.isEmpty {
                    steps.append("agent: no job and no plist for \(whose)")
                }
                for agent in present {
                    if agent.jobIsLoaded { steps.append("agent: boot out \(agent.label)") }
                    if agent.plistExists {
                        steps.append("agent: remove \(agent.plist.path(percentEncoded: false))")
                    }
                }
                if !foreignAgents.isEmpty {
                    steps.append(
                        "agent: report anything still running afterwards — booting out the job stops its own process, so only an agent somebody started by hand survives")
                }
            }
            if parts.contains(.wallpaper) {
                if registrations.isEmpty { steps.append("wallpaper: nothing is registered") }
                for registration in registrations {
                    steps.append("wallpaper: unregister \(registration.identifier)")
                    steps.append("  \(registration.path)")
                }
            }
            if parts.contains(.saver) {
                if savers.isEmpty { steps.append("screensaver: nothing installed") }
                for saver in savers {
                    steps.append("screensaver: remove \(saver.path(percentEncoded: false))")
                }
            }
            return steps
        }
    }

    public struct Surroundings: Sendable {
        public var isJobLoaded: @Sendable (String) -> Bool
        public var fileExists: @Sendable (URL) -> Bool
        public var registrations: @Sendable () -> [WallpaperInstall.Registration]
        public var runningAgents: @Sendable () -> [AgentInstall.ForeignAgent]

        public init(
            isJobLoaded: @escaping @Sendable (String) -> Bool,
            fileExists: @escaping @Sendable (URL) -> Bool,
            registrations: @escaping @Sendable () -> [WallpaperInstall.Registration],
            runningAgents: @escaping @Sendable () -> [AgentInstall.ForeignAgent]
        ) {
            self.isJobLoaded = isJobLoaded
            self.fileExists = fileExists
            self.registrations = registrations
            self.runningAgents = runningAgents
        }

        public static let live = Surroundings(
            isJobLoaded: { Launchctl.isLoaded($0) },
            // **Not following a link.** An installed saver is a symlink into
            // the app since 2026-09-21, and once the app is deleted the link
            // dangles: `fileExists(atPath:)` follows it, answers false, and the
            // link would never be removed.
            fileExists: {
                (try? FileManager.default.attributesOfItem(atPath: $0.path(percentEncoded: false))) != nil
            },
            registrations: { PluginKit.registrations(for: WallpaperInstall.extensionPoint) },
            runningAgents: { Launchctl.agentsOutsideLaunchd(named: AgentInstall.executableName) })
    }

    /// `variants` is whose to remove: every configuration's for
    /// `Scripts/uninstall.sh`, only its own for the app's Help menu, which must
    /// not take another build's agent down with it.
    public static func plan(
        removing parts: Set<Part> = Set(Part.allCases),
        variants: [BuildVariant] = BuildVariant.allCases,
        launchAgents: URL = URL.homeDirectory.appending(path: "Library/LaunchAgents"),
        screenSavers: URL = SaverInstall.destinationDirectory,
        surroundings: Surroundings = .live
    ) -> Plan {
        let agents = parts.contains(.agent)
            ? variants.map { variant -> InstalledAgent in
                let plist = launchAgents.appending(path: "\(variant.agentLabel).plist")
                return InstalledAgent(
                    label: variant.agentLabel,
                    jobIsLoaded: surroundings.isJobLoaded(variant.agentLabel),
                    plist: plist,
                    plistExists: surroundings.fileExists(plist))
            }
            : []

        let registrations = parts.contains(.wallpaper)
            ? surroundings.registrations().filter {
                variants.map(\.wallpaperExtensionIdentifier).contains($0.identifier)
            }
            : []

        let savers = parts.contains(.saver)
            ? variants
                .map { screenSavers.appending(path: "\($0.saverBundleName).saver") }
                .filter(surroundings.fileExists)
            : []

        return Plan(
            parts: parts,
            agents: agents,
            foreignAgents: parts.contains(.agent) ? surroundings.runningAgents() : [],
            registrations: registrations,
            savers: savers,
            variants: variants)
    }

    @discardableResult
    public static func apply(_ plan: Plan) throws -> [String] {
        var done: [String] = []

        if plan.parts.contains(.agent) {
            var found = false
            for agent in plan.agents where agent.isPresent {
                if agent.jobIsLoaded {
                    Launchctl.bootout(agent.label)
                    done.append("agent: booted out \(agent.label)")
                    found = true
                }
                if agent.plistExists {
                    try? FileManager.default.removeItem(at: agent.plist)
                    done.append("agent: removed \(agent.plist.path(percentEncoded: false))")
                    found = true
                }
            }
            if !found { done.append("agent: no job and no plist for \(plan.whose)") }
            // **Asked again, after the bootouts.** An agent somebody started by
            // hand is a terminal process and not this command's to end — but
            // the job's own process is, and it has just gone. Reporting the
            // list from before would name a process that no longer exists and
            // call it somebody's, which is what the shell version did.
            for other in Surroundings.live.runningAgents() {
                done.append("agent: still running outside launchd, pid \(other.pid)")
                done.append("  \(other.path)")
                done.append("  Not this command's to stop: kill \(other.pid)")
            }
        }

        if plan.parts.contains(.wallpaper) {
            for registration in plan.registrations {
                PluginKit.remove(registration.path)
                done.append("wallpaper: unregistered \(registration.identifier)")
                done.append("  \(registration.path)")
            }
            if plan.registrations.isEmpty { done.append("wallpaper: nothing was registered") }
            // **By its bundle's path, not its name.** Every configuration's
            // extension process has the same name, so a kill by name would stop
            // another build's wallpaper — the reason `WallpaperInstall.apply`
            // does it this way too.
            for registration in plan.registrations
            where Shell.run("/usr/bin/pkill", ["-f", registration.path + "/Contents/MacOS/"]).status == 0 {
                done.append("wallpaper: stopped the extension process of \(registration.identifier)")
            }
            // Unregistering a *selected* extension leaves WallpaperAgent failing
            // every acquire until it is restarted — measured 2026-09-15, the
            // desktop stuck on a fallback picture. It is macOS's own agent and
            // comes back on its own.
            if Shell.killall("WallpaperAgent") { done.append("wallpaper: restarted WallpaperAgent") }
        }

        if plan.parts.contains(.saver) {
            for saver in plan.savers {
                try? FileManager.default.removeItem(at: saver)
                done.append("screensaver: removed \(saver.path(percentEncoded: false))")
            }
            if plan.savers.isEmpty { done.append("screensaver: nothing installed") }
            for host in SaverInstall.hosts where Shell.killall(host) {
                done.append("screensaver: stopped \(host)")
            }
        }

        done.append("the library, cache and preferences are untouched")
        return done
    }
}
