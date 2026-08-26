import AppKit
import PhotoGoRoundAgentAPI
import os
import SwiftUI
import UniformTypeIdentifiers

/// The Settings panel: what is configured, and the four things you can do to it.
///
/// A standard Mac list with `+` and `−` beneath its bottom-left corner, which is
/// the shape every list-of-things panel on this platform has. The list is the
/// thing you act on: adding opens a picker, removing takes the selected row, and
/// configuring opens what that row has options for.
struct SourcesSettingsView: View {
    /// Names the scene, since this is a `Window` of the app's own rather than
    /// the `Settings` scene — see `PhotoGoRoundApp` for why it gave that up.
    static let windowID = "sources-settings"

    @State private var model = SourcesModel()
    /// The row whose options are open. A value rather than a flag, so the sheet
    /// cannot be showing while nothing is selected.
    @State private var configuring: SourceService.Source?
    /// Whether a file picker is on screen.
    ///
    /// **A modeless panel does not stop a second click on `+`.** `runModal` did
    /// that for free, at the cost of parking the main thread at
    /// user-interactive QoS while AppKit's own panel machinery works at a lower
    /// one — which the runtime reports as a priority inversion. Going modeless
    /// removes the block and hands back the one job the modality was doing, so
    /// this does it: one picker at a time, and the menu says so while it is up.
    @State private var picking = false

    var body: some View {
        VStack(spacing: 12) {
            photosPanel
            filesPanel
        }
        .padding(12)
        // The width floor is what this was pinned at. The height floor grew
        // with the second panel: 360 was the list on its own, and keeping it
        // would have let the window shrink until the list it encloses was a
        // couple of rows tall.
        .frame(
            minWidth: 520, idealWidth: 520, maxWidth: .infinity,
            minHeight: 440, idealHeight: 440, maxHeight: .infinity)
        // Both, and deliberately: the first is the panel being opened, the
        // second is this app starting up with it already open. Neither can be
        // assumed from the other.
        .task { await model.load() }
        .onAppear { model.beginPolling() }
        .onDisappear { model.endPolling() }
        .sheet(item: $configuring) { source in
            ConfigureSourceView(source: source) { recursive in
                Task { await model.setRecursive(recursive, of: source.uuid) }
            }
        }
    }

    // MARK: - The panels

    /// There is one Photos library and there will only ever be one, so this is
    /// not a list of sources you add to — it is one standing statement of which
    /// collections are in play, and a way to change it. The collections *are*
    /// sources underneath, and the lower panel deliberately does not show them.
    private var photosPanel: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                chosenCollections
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    if !model.photoCollections.isEmpty {
                        Text(photosHeld)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Select Collections…") {}
                        // No picker yet. Shown rather than hidden, because its
                        // absence is a fact about this build rather than about
                        // the product.
                        .disabled(true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            heading("Apple Photos")
        }
    }

    /// How many photographs the library has a record of across every chosen
    /// collection.
    ///
    /// **A plain sum is the true total.** One asset in three collections is one
    /// row belonging to whichever collection reached it first — see `SchemaV9`
    /// — so adding the per-source counts cannot double-count. Before the
    /// de-duplication it would have, and by a lot: overlapping collections are
    /// the normal case, not the exception.
    ///
    /// **"so far" while anything is unscanned**, for the reason `state(of:)`
    /// says "scanning…" rather than "0 photos": a collection added a
    /// moment ago has not been walked, and a number that omits it is a delay
    /// rather than an answer.
    private var photosHeld: String {
        let collections = model.photoCollections
        let total = collections.reduce(0) { $0 + $1.photos }
        let held = total == 1 ? "1 photo" : "\(total.formatted()) photos"
        return collections.contains { $0.scannedAt == nil } ? "\(held) so far" : held
    }

    /// **A `GroupBox` label is caption-sized by default**, which reads as a
    /// footnote attached to the box rather than as the name of a section. These
    /// two are the only structure the panel has, so they say so.
    private func heading(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    @ViewBuilder
    private var chosenCollections: some View {
        if model.photoCollections.isEmpty {
            Text("No collections selected.")
                .foregroundStyle(.secondary)
        } else {
            // Plain commas rather than a list formatter: this is an inventory,
            // and "Favorites, Live Photos, and Kids" reads like a sentence
            // somebody wrote.
            // **Three lines, then it truncates.** Wrapping without a bound
            // means the number of collections chosen decides how much of the
            // window is left for the list of folders, and a person who checked
            // forty of them would have pushed it off the bottom.
            Text(model.photoCollections.map(\.name).joined(separator: ", "))
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What we already had, with a box drawn round it and a name put on it.
    private var filesPanel: some View {
        GroupBox {
            VStack(spacing: 0) {
                list
                controls
            }
            .frame(maxHeight: .infinity)
        } label: {
            heading("Folders and Files")
        }
    }

    // MARK: - The list

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.fileSources) { source in
                row(source)
                    .tag(source.uuid)
                    .contextMenu {
                        Button("Configure…") { configure(source) }
                            .disabled(!source.isFolder)
                        Button("Remove") {
                            model.selection = source.uuid
                            Task { await model.removeSelected() }
                        }
                    }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .disabled(model.isWorking)
        .overlay { if model.fileSources.isEmpty { empty } }
    }

    private func row(_ source: SourceService.Source) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: source.locator))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                Text(source.locator)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(state(of: source))
                .font(.caption)
                .foregroundStyle(SourcesModel.state(of: source).available ? .secondary : Color.orange)
        }
        .padding(.vertical, 2)
        // Double-clicking a row opens its options, which is what a Mac list
        // does. It is the same act as the Configure button and the menu item.
        //
        // **`simultaneousGesture`, not `onTapGesture`.** An exclusive tap
        // gesture on a row consumes the click before the list sees it, so the
        // row highlights but the selection binding never updates — and every
        // control that reads the selection then acts on nothing.
        .contentShape(.rect)
        .simultaneousGesture(TapGesture(count: 2).onEnded { configure(source) })
    }

    /// The right-hand column: a count once there is one, and the reason instead
    /// when the source cannot be reached.
    private func state(of source: SourceService.Source) -> String {
        // Asked of the filesystem here and now — see `SourcesModel.state(of:)`.
        let standing = SourcesModel.state(of: source)
        guard standing.available else { return standing.reason ?? "unavailable" }
        // A folder added a moment ago has not been scanned yet, and saying "0
        // photos" would be a claim rather than a delay.
        guard source.scannedAt != nil else { return "scanning…" }
        return source.photos == 1 ? "1 photo" : "\(source.photos) photos"
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(model.trouble ?? "No sources")
                .font(.title3)
                .multilineTextAlignment(.center)
            if model.trouble == nil {
                Text("Add a folder or a few photos to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - The controls beneath it

    private var controls: some View {
        HStack(spacing: 0) {
            Menu {
                Button("Add Picture Files…") { addFiles() }
                Button("Add Picture Folder…") { addFolder() }
            } label: {
                // **The label carries the size, not the button.** A borderless
                // control hit-tests its content, so sizing the button instead
                // reserves space that looks clickable and is not — the glyph is
                // a few points across and every click beside it lands nowhere.
                Image(systemName: "plus")
                    .frame(width: 28, height: 22)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(model.isWorking || picking)
            .help("Add a source")

            Button {
                // Says the press happened at all. A button that is disabled
                // never runs this, so its absence is the answer: the control was
                // greyed out rather than the handler being dead.
                Log.sources.notice("panel: minus pressed")
                Task { await model.removeSelected() }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canRemoveSelection || model.isWorking)
            .help("Remove the selected source")

            Divider().frame(height: 16).padding(.horizontal, 4)

            // While a change is in flight everything is locked out, and this is
            // what says so. Without it the buttons simply stop responding, which
            // is indistinguishable from a panel that has broken.
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }

            Button {
                if let selected = model.selected { configure(selected) }
            } label: {
                Text("Configure…")
                    .padding(.horizontal, 4)
                    .frame(height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canConfigureSelection || model.isWorking)
            .help("Change what this source was added with")

            Spacer()

            // The failure from the last thing asked, beside the controls that
            // asked it rather than in a dialog that has to be dismissed.
            if let trouble = model.trouble, !model.fileSources.isEmpty {
                Text(trouble)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.bar)
        .animation(.easeInOut(duration: 0.15), value: model.isWorking)
    }

    private func configure(_ source: SourceService.Source) {
        guard source.isFolder else { return }
        model.selection = source.uuid
        configuring = source
    }

    // MARK: - The pickers

    /// Files, several at a time: a person choosing photographs chooses a
    /// handful, and each becomes a source in its own right.
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        panel.message = "Choose photos to show."
        present(panel) { panel in
            let chosen = panel.urls
            guard !chosen.isEmpty else { return }
            Task { await model.add(files: chosen) }
        }
    }

    /// One folder, with its own answer about nested folders.
    ///
    /// **One at a time on purpose.** The checkbox is a decision about *this*
    /// folder, and a multiple selection would apply one answer to folders the
    /// user never considered it for — where the expensive direction, walking a
    /// whole home directory, is the one that would be inherited.
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder of photos."

        let nested = NSButton(
            checkboxWithTitle: "Add contents of contained folders", target: nil, action: nil)
        nested.state = .off
        // A bare control handed to `accessoryView` is laid out flush against the
        // file browser above it and the buttons below, which reads as a mistake.
        // The panel gives an accessory view no margins of its own, so it has to
        // bring them.
        let inset = NSStackView(views: [nested])
        inset.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        panel.accessoryView = inset
        panel.isAccessoryViewDisclosed = true

        present(panel) { panel in
            guard let folder = panel.url else { return }
            let recursive = nested.state == .on
            Task { await model.add(folder: folder, recursive: recursive) }
        }
    }

    /// Puts a picker on screen without blocking the main thread, and holds
    /// `picking` for exactly as long as it is up — including when it is
    /// cancelled, which is the case a sentinel set in one place and cleared in
    /// another gets wrong.
    @MainActor
    private func present(_ panel: NSOpenPanel, chosen act: @escaping (NSOpenPanel) -> Void) {
        guard !picking else { return }
        picking = true
        Task {
            let response = await panel.begin()
            picking = false
            guard response == .OK else { return }
            act(panel)
        }
    }
}

/// One source's options. Everything else about it is shown so the sheet says
/// which source you are looking at, and only what can be changed is editable.
///
/// Deliberately small today, because a folder has one option. It is a sheet
/// rather than an inline disclosure because a Photos album will have several,
/// and that is the shape this has to grow into.
struct ConfigureSourceView: View {
    let source: SourceService.Source
    let apply: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recursive: Bool

    init(source: SourceService.Source, apply: @escaping (Bool) -> Void) {
        self.source = source
        self.apply = apply
        _recursive = State(initialValue: source.recursive ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: source.locator))
                    .resizable()
                    .frame(width: 32, height: 32)
                Text(source.name).font(.headline)
            }

            // The full path, which is the thing a person opens this to check.
            VStack(alignment: .leading, spacing: 2) {
                Text("Location").font(.caption).foregroundStyle(.secondary)
                Text(source.locator)
                    .textSelection(.enabled)
                    .font(.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Add contents of contained folders", isOn: $recursive)

            // Said here rather than discovered afterwards: unticking this is a
            // removal, and the photographs it drops take their deal history with
            // them.
            if source.recursive == true, !recursive {
                Text(
                    "Photographs inside contained folders will stop being shown, "
                        + "and their cached copies will be discarded."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Done") {
                    if recursive != (source.recursive ?? false) { apply(recursive) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
