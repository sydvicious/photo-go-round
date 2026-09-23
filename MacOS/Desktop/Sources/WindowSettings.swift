import PhotosGoRoundDisplay
import SwiftUI

/// The gear in a window's upper trailing corner, which opens Window Settings.
///
/// Syd, 2026-09-14: "the gear is dimmed and transparent, but visibile (against
/// the black background anyway; the picture may cause it to be not very
/// visible, and that's ok). When the user hovers over it, the gear itself
/// becomes opague, but the negative space is still transparent. It about the
/// same size as 48-point text is high, and should scale with text size
/// accesibility settings." And "in the upper trailing corner with some margin."
///
/// **An SF Symbol, because its negative space is already transparent**, so
/// hovering changes only the glyph's own opacity.
struct SettingsGear: View {
    let open: () -> Void

    /// 24 points at the default text size. **48 until Syd saw it**, 2026-09-14:
    /// "The gear is too big; make it based on 24-point text." `@ScaledMetric`
    /// is how SwiftUI follows a text-size setting; whether the Mac's setting
    /// reaches it is unverified — see `MacOS/Desktop/FEATURES.md`, *The window's
    /// picker*.
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 24
    /// The margin from the corner, which scales with the gear. 16 while the
    /// gear was 48.
    @ScaledMetric(relativeTo: .title) private var margin: CGFloat = 12

    @State private var hovering = false

    /// Dimmed at rest: visible against black, and allowed to all but vanish
    /// against a bright photograph.
    private static let resting = 0.35

    var body: some View {
        Button(action: open) {
            Image(systemName: "gearshape")
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(hovering ? 1 : Self.resting))
                // The label carries the hit area — see *A control sizes its
                // label, never itself* in FEATURES.md.
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .help("Window Settings")
        .accessibilityLabel("Window Settings")
        .padding(margin)
    }
}

/// A window's own *Shuffle All*, in a standard sheet.
///
/// Syd, 2026-09-14: "let's do a standard mac sheet; with a Done button if we
/// have to." A standard sheet has no other way to be closed, so it has one.
///
/// **Live as it changes, and never stored.** The window's interval began as a
/// copy of the screensaver's, and this changes this window and nothing else.
struct WindowSettingsSheet: View {
    @Binding var interval: ShuffleInterval
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ShuffleAllRow(selection: $interval)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 360)
    }
}

extension FocusedValues {
    /// Whether the key window's Window Settings sheet is up, so the View menu
    /// can raise it.
    @Entry var windowSettings: Binding<Bool>?
}

/// The View menu's Window Settings, acting on the key window.
///
/// Syd, 2026-09-14: "we are just removing tab support in the window, and
/// replacing it with this window settings item." Enter Full Screen stays; the
/// tab items go with `NSWindow.allowsAutomaticWindowTabbing` — see
/// `AppDelegate`.
struct WindowCommands: Commands {
    @FocusedValue(\.windowSettings) private var windowSettings

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Window Settings") { windowSettings?.wrappedValue = true }
                // Settings and About are windows too, and have no sheet.
                .disabled(windowSettings == nil)
            // Between it and Enter Full Screen, which AppKit adds below. Syd,
            // 2026-09-14: "it needs a separator."
            Divider()
        }
    }
}
