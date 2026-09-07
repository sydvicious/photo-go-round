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

    @Environment(\.openWindow) private var openWindow

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
        //
        // **480 since the collections became a list of their own.** Four
        // collection rows and five folder rows are 306 points between them
        // before either heading, the buttons beside the collections, or the
        // controls under the folders — and at 440 the two lists were squeezing
        // each other rather than scrolling, which is the whole thing bounding
        // them was for.
        .frame(
            minWidth: 520, idealWidth: 520, maxWidth: .infinity,
            minHeight: 480, idealHeight: 480, maxHeight: .infinity)
        // Both, and deliberately: the first is the panel being opened, the
        // second is this app starting up with it already open. Neither can be
        // assumed from the other.
        .task { await model.load() }
        .onAppear { model.beginPolling() }
        .onDisappear { model.endPolling() }
        // A change made in this app's own picker, rather than one the timer
        // will find eventually. See `SourceChanges`.
        //
        // A read, not a visit: the window never went away, so there is nothing
        // stale to forget. `load` would also blank whatever is on screen the
        // instant another window announced something — including a refusal the
        // person is still reading — and put it back only if the read that
        // followed happened to fail the same way.
        .onChange(of: SourceChanges.shared.revision) {
            Task { await model.refresh() }
        }
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
        Panel("Apple Photos") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    chosenCollections
                    missingCollections
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    if !model.photoCollections.isEmpty {
                        Text(photosHeld)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Select Collections…") {
                        openWindow(id: CollectionPickerView.windowID)
                    }
                    missingControls
                }
                .padding(8)
            }
            // **Padding on the column, not on the panel.** Putting it on the
            // whole `HStack` inset the list from the box as well, which read as
            // the first collection row being taller than the rest. The list
            // wants to reach the border; the buttons beside it do not.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// The albums the agent can no longer find, named, with the question the
    /// buttons beside it answer. **The words carry the meaning and the colour
    /// only underlines it**, the same orange the folder list uses for a source
    /// it cannot reach. See `Missing Albums Plan.md`, Phase 4.
    @ViewBuilder
    private var missingCollections: some View {
        if let message = model.missingAlbumsMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                // Its own, for the same reason: the list above it reaches the
                // border and this must not.
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
    }

    /// Remove and Reconnect, shown only while something is missing.
    ///
    /// Reconnect is enabled when the agent found exactly one successor for at
    /// least one missing album, and acts on those; the rest stay listed with
    /// Remove. Both act on every album they apply to at once — see
    /// `SourcesModel.removeMissing`. The spinner says a change is in flight,
    /// since the buttons are locked out meanwhile and a silent lockout looks
    /// like a broken panel.
    @ViewBuilder
    private var missingControls: some View {
        if !model.missingCollections.isEmpty {
            HStack(spacing: 6) {
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
                Button("Reconnect") {
                    Log.sources.notice("panel: reconnect missing albums pressed")
                    Task { await model.reconnectMissing() }
                }
                .disabled(!model.canReconnect || model.isWorking)
                .help("Point each missing album at the one album that matches what it was called and where it sat")
                Button("Remove") {
                    Log.sources.notice("panel: remove missing albums pressed")
                    Task { await model.removeMissing() }
                }
                .disabled(model.isWorking)
                .help("Remove the missing albums, their photographs, and their cached copies")
            }
            .controlSize(.small)
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

    /// How tall a row is, near enough: a 24-point icon with two points of
    /// padding either side, plus what `List` adds around it.
    private static let rowHeight: CGFloat = 34

    /// **Four collections at the smallest the window goes**, and a scroll bar
    /// past that. Between three and five was the ask; four is the middle of it.
    /// It is a floor rather than a height — dragging the window taller shows
    /// more collections, not a taller empty box.
    private static let collectionRows = 4

    /// **Five folders at the smallest the window goes**, and a scroll bar past
    /// that. A floor is what stops the number of sources deciding how much
    /// window everything else gets; before this the folder list simply grew
    /// until it had pushed the rest off the bottom.
    private static let fileRows = 5

    /// The collections in play, each saying where it stands.
    ///
    /// **It was a comma-joined sentence of names until 2026-09-07**, capped at
    /// three lines so that ticking forty of them could not push the folder list
    /// off the bottom of the window. What that could not say is the thing most
    /// worth saying: *this one is not reachable*. A library that had stopped
    /// answering left its albums looking exactly like albums that were fine,
    /// and the only source state anywhere in this window was in the folder list
    /// underneath.
    ///
    /// A bounded, scrolling list solves the same layout problem the truncation
    /// was there for, and has somewhere to put the state.
    @ViewBuilder
    private var chosenCollections: some View {
        if model.photoCollections.isEmpty {
            // Padded on its own, because the list beside it deliberately is
            // not: words touching the border read as a mistake, a list reaching
            // it reads as a list.
            Text(
                model.hasRead
                    ? "No collections selected."
                    : model.readFailure ?? "Looking for collections…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } else {
            List(model.collectionRows) { node in
                if let collection = node.item {
                    collectionRow(collection, depth: node.depth)
                } else {
                    folderRow(node.title, depth: node.depth)
                }
            }
            // **`.plain`, not `.inset`.** The inset style pads its content on
            // every side by an amount it does not expose, and inside a box of
            // our own that reads as the first row being taller than the rest
            // rather than as a margin. The stripes were the only reason to want
            // it, and `alternatingRowBackgrounds` gives those to a plain list.
            .listStyle(.plain)
            .alternatingRowBackgrounds()
            // **A floor, not a height.** Four rows is what it must never drop
            // below; past that the window's own height decides, and dragging it
            // taller shows more collections rather than more empty box.
            .frame(
                minHeight: Self.rowHeight * CGFloat(Self.collectionRows),
                maxHeight: .infinity)
        }
    }

    /// One collection: what it is called, where it sits in the library, and
    /// where it stands.
    ///
    /// **No file icon**, because a collection is not a file — the locator is an
    /// identifier, and `NSWorkspace.icon(forFile:)` on one produces the generic
    /// document icon, which says nothing and looks like a mistake.
    /// A folder in the library's tree: a label and nothing else.
    ///
    /// **Photos folders hold albums rather than photographs**, so there is no
    /// state to report and nothing to act on — which is why this draws no
    /// status column rather than an empty one.
    private func folderRow(_ title: String, depth: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(depth) * Self.indent)
    }

    /// How far one level of the library's folder tree steps in.
    private static let indent: CGFloat = 14

    private func collectionRow(_ source: SourceService.Source, depth: Int) -> some View {
        let standing = Self.standing(of: source)
        return HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(source.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(standing.words)
                .font(.caption)
                .foregroundStyle(standing.isTrouble ? Color.orange : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                // The reasons are whole sentences now — "the photo library did
                // not answer enumerateImages within 10.0 seconds" — so the
                // column truncates and hovering gives the whole thing.
                .help(standing.words)
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(depth) * Self.indent)
    }

    /// Where a source the app cannot see for itself stands.
    ///
    /// **Only the agent can answer this**, unlike a folder — there is no path to
    /// `stat`. So this reads what the last scan concluded, which is exactly what
    /// the agent sends and what `wire` is careful never to guess at.
    ///
    /// **The words carry it and the colour only underlines it**, the same rule
    /// the folder rows and the missing-albums line already follow.
    static func standing(of source: SourceService.Source) -> (words: String, isTrouble: Bool) {
        if source.isMissing { return ("not in this library", true) }
        if !source.available { return (source.unavailableReason ?? "unavailable", true) }
        // Added a moment ago and not yet walked. Saying "0 photos" would be a
        // claim rather than a delay — the same reason a folder says "scanning…".
        if source.scannedAt == nil { return ("scanning…", false) }
        return (source.photos == 1 ? "1 photo" : "\(source.photos.formatted()) photos", false)
    }

    /// What we already had, with a box drawn round it and a name put on it.
    private var filesPanel: some View {
        Panel("Folders and Files") {
            VStack(spacing: 0) {
                list
                // **A drawn rule rather than `Divider()`.** A `Divider` is a
                // hairline in a colour chosen for a window background, and this
                // sits on `controlBackgroundColor` inside a panel — where it is
                // there, and invisible. The same token the panel's own border
                // uses, so the two read as one drawing.
                //
                // The picker has a `Divider` in the same place and keeps it: it
                // is on the window background, which is what that colour was
                // picked against.
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                controls
            }
            .frame(maxHeight: .infinity)
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
        // `.plain` with stripes, for the reason the collections list above
        // says: the inset style's own padding is what pushed the first row down.
        .listStyle(.plain)
        .alternatingRowBackgrounds()
        .disabled(model.isWorking)
        // A floor rather than a height, for the same reason the collections
        // list has one: five rows is the least it may be, and a taller window
        // spends its extra height on both lists rather than on padding.
        .frame(minHeight: Self.rowHeight * CGFloat(Self.fileRows), maxHeight: .infinity)
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

    /// **What this list has in it, and nothing else.**
    ///
    /// It used to show `model.trouble` here instead of "No sources", which put
    /// whatever had last gone wrong into the middle of the panel at title size.
    /// A photo library that stopped answering therefore filled the folders-and-
    /// files half of Settings with a sentence about Photos — a part of the
    /// window it says nothing about, over a list whose contents are on a disk
    /// this app can see for itself.
    ///
    /// Trouble belongs in the status line beside the controls, where it is
    /// reported without displacing anything. This says one thing: there are no
    /// folders or files yet.
    private var empty: some View {
        VStack(spacing: 6) {
            // **Not "No sources" until somebody has looked.** An empty list
            // before the first answer means nothing has been asked, and saying
            // there are none states a fact nobody has established — over a
            // library that may hold a hundred folders.
            //
            // A read that failed is reported *here and only here*: this is the
            // one case with nothing else to show, so the words are the whole
            // answer rather than an interruption over a list.
            Text(model.hasRead ? "No sources" : model.readFailure ?? "Looking for sources…")
                .font(.title3)
                .multilineTextAlignment(.center)
            if model.hasRead {
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
            //
            // **Unconditional now.** It used to be hidden when there were no
            // file sources, because the empty state showed it instead — so the
            // one place a failure could not be reported quietly was the one
            // where it took over the panel.
            if let trouble = model.trouble {
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

/// A named section of the Settings window: a heading, and a box holding it.
///
/// **Hand-drawn rather than a `GroupBox`, since 2026-09-07.** `GroupBox` insets
/// its content by an amount it does not expose, which pushed the whole of each
/// panel down inside its own border — read from the window as the first row of
/// each list being taller than the rest. Every attempt to remove it from the
/// list was aimed at the wrong thing, because the list was not what had moved.
///
/// The border, the fill, and the padding are all things this window has an
/// opinion about, so it states them rather than inheriting an opinion it cannot
/// see. **A heading rather than a `GroupBox` label** for the reason that label
/// was overridden before this existed: the default is caption-sized, which reads
/// as a footnote attached to a box rather than as the name of a section.
private struct Panel<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    /// Matches the radius AppKit uses for a box of this kind, so the two panels
    /// look like the rest of the system rather than like each other only.
    private static var radius: CGFloat { 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor))
                // Clipped rather than inset: a list inside should reach the
                // border and take its corners from it, which is what makes the
                // first row start where the box starts.
                .clipShape(RoundedRectangle(cornerRadius: Self.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.radius)
                        .strokeBorder(Color(nsColor: .separatorColor))
                }
        }
        .frame(maxHeight: .infinity)
    }
}
