import Foundation
import PhotoGoRoundKit
import ServiceManagement

/// Registering the agent as a login item, and asking what it is doing.
///
/// `SMAppService.agent(plistName:)` is what removes the installer. The launchd
/// plist lives inside the bundle at `Contents/Library/LaunchAgents/`, the app
/// registers it with one call, and the user sees and controls it in System
/// Settings → General → Login Items. No `launchctl`, no writing into
/// `~/Library/LaunchAgents`, no privileged install step — and no uninstaller to
/// write, since unregistering is also one call.
///
/// A **LaunchAgent, not a LaunchDaemon**: Photos access is per-user TCC and
/// needs a user session, so a system daemon could not reach the library at all.
///
/// In the shipping shape this bundle lives inside the main app's
/// `Contents/Library/LoginItems/` and the app registers it. Until there is an
/// app — Phase 3 — the bundle registers itself, which works because
/// `agent(plistName:)` resolves against the calling bundle either way.
struct ServiceCommand {
    enum Action { case register, unregister, status }

    var action: Action

    /// Must match the plist filename in `Contents/Library/LaunchAgents/`.
    static let plistName = "com.sydpolk.photogoround.server.plist"

    func run() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Console.failure(
                """
                not running from an app bundle.

                SMAppService registers a plist inside the calling bundle, so this
                only works from the built bundle rather than from `swift run`:

                    ./Scripts/make-agent-bundle.sh
                    "./build/Photo-Go-Round Server.app/Contents/MacOS/photogoroundd" \(label)
                """
            )
            throw ExitCode(1)
        }

        let service = SMAppService.agent(plistName: Self.plistName)

        switch action {
        case .status:
            report(service.status)

        case .register:
            // Registering adds a login item to this Mac. It is deliberately an
            // explicit verb rather than something a run does on startup.
            try service.register()
            Console.recovered("registered. Check System Settings → General → Login Items.")
            report(service.status)

        case .unregister:
            try service.unregister()
            Console.recovered("unregistered")
            report(service.status)
        }
    }

    private var label: String {
        switch action {
        case .register: "register"
        case .unregister: "unregister"
        case .status: "service-status"
        }
    }

    private func report(_ status: SMAppService.Status) {
        let description: String
        switch status {
        case .notRegistered:
            description = "not registered"
        case .enabled:
            description = "enabled — launchd will start it at login and restart it if it crashes"
        case .requiresApproval:
            description = "registered, but waiting for you to approve it in System Settings → General → Login Items"
        case .notFound:
            // The most useful failure to be specific about: it means launchd
            // would not accept the plist, and the reason is almost never that
            // the file is absent.
            let plist = Bundle.main.bundleURL
                .appending(path: "Contents/Library/LaunchAgents")
                .appending(path: Self.plistName)
            let present = FileManager.default.fileExists(atPath: plist.path(percentEncoded: false))
            description = """
                not found. Bundle: \(Bundle.main.bundleURL.path(percentEncoded: false))
                    plist \(present ? "is present" : "is MISSING") at Contents/Library/LaunchAgents/\(Self.plistName)
                """
        @unknown default:
            description = "unknown (\(status.rawValue))"
        }
        Console.note("status: \(description)")
    }
}

/// Lets a command exit non-zero without the error text being printed twice.
struct ExitCode: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
}
