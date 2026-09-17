import AppKit
import OSLog
import PhotoGoRoundDisplay
import PhotoGoRoundAgentAPI

/// The moments SwiftUI's scenes give none of: before the first window, and
/// once the application has finished launching.
///
/// **The app is not the wallpaper.** It hosted a wallpaper loop of its own from
/// 2026-09-10 until 2026-09-16, started here; the wallpaper is the extension
/// now, chosen in System Settings, and the app only writes its interval. Syd:
/// "remove the whole in-app loop; we might need it later for sandboxed app, but
/// for now it is gone."
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// **No tabs.** Syd, 2026-09-14: "we are just removing tab support in the
    /// window, and replacing it with this window settings item." Turning
    /// automatic tabbing off takes Show Tab Bar and Show All Tabs out of the
    /// View menu with it; Enter Full Screen stays. Set here so it is in place
    /// before the first window.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// `menu:` lines, filterable in one word.
    private let menuLog = Logger(subsystem: Log.subsystem, category: "menu")
    /// Held for the life of the app; see `watchTheViewMenu()`.
    private var menuObserver: (any NSObjectProtocol)?
    /// The last View menu logged, so an unchanged menu is not a line per click.
    private var loggedViewMenu: String?

    /// **What the View menu actually holds**, logged at launch and whenever the
    /// menu bar is opened. Syd, 2026-09-14: "there is no divider and Enter Full
    /// Screen item." AppKit inserts that item itself, and whether turning
    /// tabbing off or SwiftUI rebuilding the menu is what loses it has not been
    /// measured; these lines are the measurement.
    private func watchTheViewMenu() {
        Task { @MainActor [weak self] in self?.logViewMenu(at: "launch") }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // The identity, not the menu: it is `Sendable`, and the menu bar
            // itself may only be read on the main actor.
            let tracking = (notification.object as? NSMenu).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard tracking == NSApp.mainMenu.map(ObjectIdentifier.init) else { return }
                self?.logViewMenu(at: "menu bar opened")
            }
        }
    }

    private func logViewMenu(at moment: String) {
        guard let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else {
            menuLog.notice("menu: no View menu at \(moment, privacy: .public)")
            return
        }
        let items = view.items.map { item in
            item.isSeparatorItem
                ? "—"
                : "\(item.title) [\(item.action.map(NSStringFromSelector) ?? "no action")]"
        }.joined(separator: ", ")
        guard items != loggedViewMenu else { return }
        loggedViewMenu = items
        menuLog.notice("menu: View at \(moment, privacy: .public): \(items, privacy: .public)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        watchTheViewMenu()
    }
}
