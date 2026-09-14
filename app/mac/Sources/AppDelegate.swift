import AppKit
import OSLog
import PhotoGoRoundDisplay

/// The one thing SwiftUI's scenes give no moment for: starting the wallpaper
/// once the application has finished launching, and keeping it for as long as
/// the app runs.
///
/// **The app hosts the wallpaper; it is not the wallpaper.** Everything it does
/// is `Wallpaper`, in the display library, so a binary of its own can host the
/// same loop later. See `Wallpaper Plan.md`, *Where the loop runs*.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let wallpaper = Wallpaper.desktop()

    /// **No tabs.** Syd, 2026-09-14: "we are just removing tab support in the
    /// window, and replacing it with this window settings item." Turning
    /// automatic tabbing off takes Show Tab Bar and Show All Tabs out of the
    /// View menu with it; Enter Full Screen stays. Set here so it is in place
    /// before the first window.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// `menu:` lines, filterable in one word.
    private let menuLog = Logger(subsystem: "com.sydpolk.photogoround", category: "menu")
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
        wallpaper.watchTheSystem()
        // Runs only if *Also set wallpapers* is ticked.
        wallpaper.resume()
    }
}
