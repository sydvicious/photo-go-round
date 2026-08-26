import AppKit
import PhotoGoRoundAgentAPI
import SwiftUI

/// Choosing which collections in the photo library are in play.
///
/// **A chooser, not an adder.** Every collection is listed with a checkbox, and
/// what is ticked when you press Done *is* the set of Photos sources. That is
/// why it opens showing what is already true, and why unticking removes a
/// source rather than doing nothing.
struct CollectionPickerView: View {
    static let windowID = "collection-picker"

    @Environment(\.dismissWindow) private var dismissWindow

    @State private var model = CollectionsModel()

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            controls
        }
        .frame(
            minWidth: 460, idealWidth: 520, maxWidth: .infinity,
            minHeight: 420, idealHeight: 560, maxHeight: .infinity)
        .task { await model.load() }
        .onAppear { model.beginPolling() }
        .onDisappear { model.endPolling() }
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if let library = model.library, !library.isReadable {
            unauthorized(library.authorization)
        } else if model.library == nil {
            message(model.trouble ?? "Asking the agent what is in your library…")
        } else if model.visible.isEmpty {
            message("This photo library has no collections.")
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.tree) { top in
                    // An album at the top of the tree is Favorites, which has no
                    // heading and nothing under it.
                    if let collection = top.collection {
                        row(collection, depth: 0, prominent: true)
                    } else {
                        Section {
                            if !model.isCollapsed(top.id) {
                                ForEach(model.rows(under: top)) { node in
                                    if let collection = node.collection {
                                        row(collection, depth: node.depth)
                                    } else {
                                        twisty(node, isSection: false)
                                    }
                                }
                            }
                        } header: {
                            twisty(top, isSection: true)
                        }
                    }
                }
            }
        }
    }

    /// A twisty, a name, and what is inside it — for a section heading and for
    /// a folder alike, since they differ only in weight, indent, and backing.
    ///
    /// **The whole row is the hit target**, not the triangle: a chevron is a
    /// few points across, and a control that only responds on the glyph is the
    /// fault the `−` button in Settings had.
    private func twisty(_ node: PickerNode, isSection: Bool) -> some View {
        HStack(spacing: 6) {
            // **Outside the collapse button, not inside it.** A control nested
            // in another control never sees its own clicks, and this row now
            // does two separate things.
            if !isSection {
                MixedCheckbox(state: Self.state(model.chosen(under: node))) {
                    model.chooseAll(under: node)
                }
                // **A represented view claims all the width it is offered.**
                // Without this the checkbox took the row and pushed the folder's
                // name to the right edge. An `NSButton` checkbox knows its own
                // size; this is what lets it use it.
                .fixedSize()
                .frame(width: 16, alignment: .leading)
                .padding(.leading, CGFloat(node.depth) * 16 + 12)
            }
            collapser(node, isSection: isSection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func state(_ chosen: CollectionsModel.Chosen) -> NSControl.StateValue {
        switch chosen {
        case .none: .off
        case .some: .mixed
        case .all: .on
        }
    }

    private func collapser(_ node: PickerNode, isSection: Bool) -> some View {
        let shut = model.isCollapsed(node.id)
        let albums = node.albums.count
        let ticked = model.chosenCount(under: node)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { model.toggle(node.id) }
        } label: {
            HStack(spacing: 4) {
                // **A fixed gutter, not the glyph's own width.** A chevron is
                // narrower than a checkbox, so letting it size itself started
                // every heading a few points left of every row beneath it —
                // visible as soon as Favorites appeared above them.
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(shut ? 0 : 90))
                    .frame(width: 18, alignment: .leading)
                if !isSection {
                    // Photos draws a folder, and the icon is also what says
                    // this row is not something you can tick.
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                Text(node.title)
                    .font(isSection ? .headline : .body)
                    .lineLimit(1)
                Text("\(albums)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if ticked > 0 {
                    Text("· \(ticked) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(.leading, isSection ? CGFloat(node.depth) * 16 + 12 : 0)
            .padding(.trailing, 12)
            .padding(.vertical, isSection ? 6 : 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(isSection ? AnyShapeStyle(.bar) : AnyShapeStyle(Color.clear))
        .help(shut ? "Show \(node.title)" : "Hide \(node.title)")
    }

    /// Checkbox, then the name across whatever width there is, then the count
    /// hard right — so the numbers form a column that can be read down.
    ///
    /// **No folder path on the row.** The tree says where an album lives by
    /// where the row sits, which is how Photos says it; a path repeated under
    /// every album in a folder is one sentence written once per line.
    private func row(
        _ collection: SourceService.Library.Collection, depth: Int, prominent: Bool = false
    ) -> some View {
        Toggle(isOn: binding(for: collection.identifier)) {
            HStack(spacing: 8) {
                Text(collection.title.isEmpty ? "Untitled" : collection.title)
                    // Favorites sits above the headings, so it carries their
                    // weight — a plain row up there reads as something that
                    // fell out of the list below it.
                    .font(prominent ? .headline : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                count(of: collection)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.leading, CGFloat(depth) * 16 + 12)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .contentShape(.rect)
    }

    /// **Absent is not zero.** A collection the agent has not counted yet shows
    /// nothing at all; one it has counted and found empty shows `0`, which is a
    /// fact worth having before you tick it.
    @ViewBuilder
    private func count(of collection: SourceService.Library.Collection) -> some View {
        if let number = collection.count {
            Text(number == 1 ? "1 photo" : "\(number.formatted()) photos")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func binding(for identifier: String) -> Binding<Bool> {
        Binding(
            get: { model.chosen.contains(identifier) },
            set: { isOn in
                if isOn {
                    model.chosen.insert(identifier)
                } else {
                    model.chosen.remove(identifier)
                }
            })
    }

    // MARK: - The states that are not a list

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// **A state to show, with the button that changes it.** `PLAN.md`'s
    /// *Showing unavailability* is the governing rule: a refusal is an answer,
    /// not an error, and the job here is to say where it gets changed.
    @ViewBuilder
    private func unauthorized(_ authorization: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Text("Photo Go Round has no access to your photo library.")
                .font(.headline)
            if authorization == "notDetermined" {
                Text("The agent will ask, and macOS will show the prompt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Allow Access…") { Task { await model.requestAccess() } }
                    .disabled(model.isWorking)
            } else {
                // Once somebody has decided, nothing this app does can reopen
                // the prompt — so it says where the decision lives instead of
                // offering a button that would do nothing.
                Text("Change it in System Settings › Privacy & Security › Photos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Beneath it

    private var controls: some View {
        HStack(spacing: 10) {
            status
            Spacer()
            Button("Cancel") { dismissWindow(id: Self.windowID) }
                .keyboardShortcut(.cancelAction)
            Button("Done") {
                Task {
                    if await model.apply() { dismissWindow(id: Self.windowID) }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isWorking || !model.hasChanges)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        if let trouble = model.trouble {
            Text(trouble)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if model.isWorking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Saving…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let library = model.library, library.isCounting {
            // Says why numbers are missing, rather than leaving blanks to be
            // read as zero.
            Text("Counting \(library.counted.formatted()) of \(library.total.formatted())…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(
                model.chosenCount == 1
                    ? "1 collection selected" : "\(model.chosenCount) collections selected"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// A checkbox that can say "some of them".
///
/// **AppKit, because SwiftUI's `Toggle` has two states.** A folder holding four
/// ticked albums out of nine is neither on nor off, and approximating a mixed
/// checkbox out of SF Symbols would be a control that looks *nearly* like the
/// real one — which is worse than using the real one.
///
/// The button's own state is never trusted: `allowsMixedState` makes a click
/// cycle off → on → mixed, which is not what this means. The click is reported
/// upward, the model decides, and `updateNSView` puts the displayed state back
/// to whatever the albums underneath now say.
private struct MixedCheckbox: NSViewRepresentable {
    let state: NSControl.StateValue
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: "", target: context.coordinator,
            action: #selector(Coordinator.fire))
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = state
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
