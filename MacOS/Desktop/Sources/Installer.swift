import Foundation
import OSLog
import Observation
import PhotosGoRoundAgentAPI
import PhotosGoRoundInstall
import SwiftUI

/// Installs what this app's wrapper carries: at every launch, and whenever the
/// Help menu says to.
///
/// `LaunchInstall` holds the judgement and the doing; this is the part with a
/// window — the spinner, the lockout, and a thread to block on.
/// `Plans/Release App Installer.md`, Phase 4.
@MainActor
@Observable
final class Installer {

    static let shared = Installer()

    /// Whether an install or uninstall is running. Every control that goes to
    /// the agent is disabled meanwhile: the agent may be restarting under it.
    private(set) var isBusy = false
    /// What is being done, for the words beside the spinner.
    private(set) var activity = ""

    /// What this app's wrapper holds, read once: it does not change while the
    /// app runs.
    let carried = LaunchInstall.carried(in: Bundle.main.bundleURL)

    private var startedAtLaunch = false

    /// Called once, from `applicationDidFinishLaunching`.
    ///
    /// **Every build installs and restarts the agent; only Release does the
    /// rest unasked.** `LaunchInstall.run` has the sequence.
    func startAtLaunch() {
        guard !startedAtLaunch else { return }
        startedAtLaunch = true
        guard !carried.isEmpty else {
            Log.install.notice("install: this app carries nothing to install")
            return
        }
        let carried = carried
        perform("Checking what is installed…") { report in
            LaunchInstall.run(
                carried,
                progress: { words in
                    Task { @MainActor in Installer.shared.activity = words }
                },
                report: report)
        }
    }

    /// The Help menu's Install — always, whatever is there.
    func install(_ product: LaunchInstall.Product) {
        Log.install.notice("install: menu asked to install \(product.rawValue, privacy: .public)")
        let carried = carried
        perform("Installing \(product.noun)…") { report in
            LaunchInstall.install(product, from: carried, report: report)
        }
    }

    /// The Help menu's Uninstall — this build's own, never another's.
    func uninstall(_ product: LaunchInstall.Product) {
        Log.install.notice("install: menu asked to uninstall \(product.rawValue, privacy: .public)")
        perform("Uninstalling \(product.noun)…") { report in
            LaunchInstall.uninstall(product, report: report)
        }
    }

    /// Runs `work` with the spinner up and the controls locked, one at a time.
    ///
    /// **On a Dispatch thread, not the cooperative pool.** The installs block —
    /// up to ten seconds for launchd to forget a job, thirty for `pkd` to write
    /// a record, thirty for the agent to answer — and a pool thread held that
    /// long is one the app's own work cannot have.
    private func perform(
        _ words: String, _ work: @escaping @Sendable (_ report: (String) -> Void) -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        activity = words
        Task {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    work { line in Log.install.notice("install: \(line, privacy: .public)") }
                    done.resume()
                }
            }
            isBusy = false
        }
    }
}

/// Install and uninstall for each piece, under the Help menu. Syd, 2026-09-21:
/// "the app should also have a menu under the help menu to install and
/// uninstall the various pieces."
struct InstallCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .help) {
            let installer = Installer.shared
            Divider()
            ForEach(LaunchInstall.order, id: \.self) { product in
                Button("Install \(product.title)") { installer.install(product) }
                    .disabled(installer.isBusy || installer.carried[product] == nil)
            }
            Divider()
            ForEach(LaunchInstall.order, id: \.self) { product in
                Button("Uninstall \(product.title)") { installer.uninstall(product) }
                    .disabled(installer.isBusy)
            }
        }
    }
}

extension LaunchInstall.Product {
    /// For a menu item.
    var title: String {
        switch self {
        case .agent: "Agent"
        case .wallpaper: "Wallpaper"
        case .saver: "Screensaver"
        }
    }
}

/// The spinner and its words, shown while `Installer` is busy.
struct InstallingBadge: View {
    var body: some View {
        let installer = Installer.shared
        if installer.isBusy {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(installer.activity)
                    .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .capsule)
            .padding(12)
            .transition(.opacity)
        }
    }
}
