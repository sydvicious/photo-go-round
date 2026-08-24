import AppKit
import PhotoGoRoundKit
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
    @State private var model = SourcesModel()
    /// The row whose options are open. A value rather than a flag, so the sheet
    /// cannot be showing while nothing is selected.
    @State private var configuring: SourceService.Source?

    var body: some View {
        VStack(spacing: 0) {
            list
            controls
        }
        .frame(width: 520, height: 360)
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

    // MARK: - The list

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.sources) { source in
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
        .overlay { if model.sources.isEmpty { empty } }
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
        // photographs" would be a claim rather than a delay.
        guard source.scannedAt != nil else { return "scanning…" }
        return source.photos == 1 ? "1 photograph" : "\(source.photos) photographs"
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(model.trouble ?? "No sources")
                .font(.title3)
                .multilineTextAlignment(.center)
            if model.trouble == nil {
                Text("Add a folder or a few photographs to get started.")
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
                // The provider does not exist yet. Shown rather than hidden,
                // because its absence is a fact about this build rather than
                // about the product.
                Button("Add from Photos Library…") {}
                    .disabled(true)
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
            .disabled(model.isWorking)
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
            if let trouble = model.trouble, !model.sources.isEmpty {
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
        panel.message = "Choose photographs to show."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let chosen = panel.urls
        Task { await model.add(files: chosen) }
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
        panel.message = "Choose a folder of photographs."

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

        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let recursive = nested.state == .on
        Task { await model.add(folder: folder, recursive: recursive) }
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
