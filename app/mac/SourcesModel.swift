import Foundation
import Observation
import os
import PhotoGoRoundKit

/// What the Settings panel knows and does, with no view in it.
///
/// Separated from the panel because everything interesting here is *behaviour* —
/// what a refusal does to the list, whether Configure is available for the
/// selected row, what happens to the selection when the source under it goes
/// away — and none of it should need a window to exercise.
///
/// **The agent is the only source of truth.** Nothing is added to the list
/// locally and confirmed later: a change is sent, the answer is what the list
/// becomes, and anything that failed leaves the list as it was with the reason
/// beside it.
@MainActor
@Observable
final class SourcesModel {
    private let service: SourceService

    /// What the agent says is configured, newest last — the order it returns,
    /// which is the order they were added.
    private(set) var sources: [SourceService.Source] = []
    /// Single selection, by `uuid`. The panel is a list of things you act on one
    /// at a time.
    var selection: String? {
        didSet {
            Log.sources.notice(
                "panel: selection \(self.selection ?? "none", privacy: .public) — can remove \(self.canRemoveSelection, privacy: .public), working \(self.isWorking, privacy: .public)"
            )
        }
    }
    /// What went wrong with the last thing asked, in words meant to be read.
    /// Cleared by the next thing that works.
    private(set) var trouble: String?
    /// True while a change is in flight, so the panel can refuse to fire a
    /// second one on top of it.
    private(set) var isWorking = false

    /// How often the list is re-read while the panel is open.
    ///
    /// **Minutes, not seconds.** Opening Settings re-reads it, and after that the
    /// only things that change without this app touching anything are somebody
    /// using `pgr_ctl`, a drive coming or going, and a scan finishing — none of
    /// which is worth a request every few seconds. Where a source *stands* is
    /// not asked over HTTP at all; the app looks at the path itself, every time
    /// it draws.
    static let pollInterval = Duration.seconds(180)

    /// How soon to look again after something went wrong.
    ///
    /// The one case worth being prompt about: the agent was not answering, and
    /// noticing that it is back should not take three minutes.
    static let retryInterval = Duration.seconds(15)

    private var poll: Task<Void, Never>?
    /// How long this instance waits between reads. The statics are the answer
    /// for the panel; a test supplies its own, because a test that waits three
    /// real minutes to prove a timer stopped is a test nobody will run.
    private let interval: Duration
    private let retry: Duration

    init(
        service: SourceService,
        interval: Duration = SourcesModel.pollInterval,
        retry: Duration = SourcesModel.retryInterval
    ) {
        self.service = service
        self.interval = interval
        self.retry = retry
    }

    /// The ordinary case: the agent this checkout's development runs talk to.
    /// The domain is never spelled here, so the app and the agent cannot
    /// disagree about which deployment they are in.
    convenience init() {
        self.init(
            service: SourceService(
                preferences: MacHostEnvironment(deployment: .development).preferences))
    }

    // MARK: - Reading

    /// Asks the agent what it has. Never throws: this is called on a timer and
    /// on appearance, and a failure is something to *show*, not to propagate.
    func load() async {
        do {
            let listed = try await service.list()
            let previous = sources
            sources = listed
            Log.sources.notice(
                "panel: read \(listed.count, privacy: .public) sources, selection \(self.selection ?? "none", privacy: .public)"
            )
            trouble = nil
            // A source removed by something else — `pgr_ctl`, another window —
            // must not leave the panel with a selection pointing at nothing,
            // because every button reads the selection to decide what it does.
            if let selection, !listed.contains(where: { $0.uuid == selection }) {
                // **Follow it by locator first.** A source can keep its place in
                // the list and change identity: anything that removes it from
                // the durable list and puts it back mints a new `uuid`. Dropping
                // the selection then leaves a row that still looks chosen while
                // every button reads *nothing selected* — one click, and nothing
                // happens, with no way to tell why.
                let was = selected(uuid: selection, in: previous)?.locator
                self.selection = was.flatMap { locator in
                    listed.first { $0.locator == locator }?.uuid
                }
            }
        } catch {
            trouble = Self.explain(error)
        }
    }

    /// Starts re-reading while the panel is on screen. Idempotent, because
    /// `onAppear` fires again when the window is reopened.
    func beginPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                let failed = await self?.trouble != nil
                let wait = await failed ? (self?.retry ?? Self.retryInterval)
                    : (self?.interval ?? Self.pollInterval)
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// Stops when the panel goes away. A settings window nobody is looking at
    /// should not be asking the agent anything.
    func endPolling() {
        poll?.cancel()
        poll = nil
    }

    // MARK: - Changing

    /// One request for the whole selection, so a hundred files chosen at once is
    /// one write and one doorbell.
    func add(files: [URL]) async {
        await change { try await self.service.add(files: files) }
    }

    func add(folder: URL, recursive: Bool) async {
        await change { try await self.service.add(folder: folder, recursive: recursive) }
    }

    /// Removes the selected source. The selection is cleared first, because the
    /// row it names is about to stop existing.
    func removeSelected() async {
        Log.sources.notice(
            "panel: remove asked for \(self.selection ?? "none", privacy: .public), working \(self.isWorking, privacy: .public)"
        )
        guard let uuid = selection else { return }
        selection = nil
        await change { try await self.service.remove(uuid) }
    }

    func setRecursive(_ recursive: Bool, of uuid: String) async {
        await change { try await self.service.setRecursive(recursive, of: uuid) }
    }

    /// Every change is the same three steps: ask, then re-read, and say what
    /// went wrong if anything did.
    ///
    /// **Re-reading rather than patching the list from the answer.** A `POST`
    /// tells us what was created but not what else has changed since — a count
    /// that finished arriving, a drive that went away — and one shape for every
    /// change is worth more here than saving a request.
    private func change<T>(_ work: @escaping () async throws -> T) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        var failure: String?
        do {
            _ = try await work()
        } catch {
            failure = Self.explain(error)
        }

        // The list is re-read either way, because a refusal says nothing about
        // what else has changed since. **Then the failure is put back**: the
        // reload succeeds — listing works fine when a change was refused — and
        // it clears `trouble` on its way, which would erase the only account of
        // why the thing the user just asked for did not happen.
        await load()
        if let failure { trouble = failure }
    }

    // MARK: - Where a source stands, asked here rather than remembered

    /// What to show in the state column, decided **now**.
    ///
    /// The agent's answer is a round trip old before it is drawn, and for a
    /// file-backed source there is no reason to take one: this app is
    /// unsandboxed, it has the path in front of it, and `stat` is cheaper than
    /// asking. It runs the kit's own rule so the two ends cannot disagree about
    /// what "unavailable" means.
    ///
    /// Kinds this process cannot see — a Photos album, a Google album — keep
    /// whatever the agent said, because it is the only one that can look.
    static func state(of source: SourceService.Source) -> (available: Bool, reason: String?) {
        guard SourceKind(source.kind).isFileBacked else {
            return (source.available, source.unavailableReason)
        }
        switch SourceAvailability.of(path: source.locator) {
        case .available: return (true, nil)
        case .offline(let why), .gone(let why): return (false, why)
        }
    }

    // MARK: - What the panel asks about the selection

    var selected: SourceService.Source? {
        sources.first { $0.uuid == selection }
    }

    private func selected(uuid: String, in list: [SourceService.Source]) -> SourceService.Source? {
        list.first { $0.uuid == uuid }
    }

    /// Configure is for options, and today only a folder has one. A file source
    /// has nothing to configure, so the button is not offered rather than
    /// opening a sheet with a checkbox that cannot apply.
    var canConfigureSelection: Bool {
        selected?.isFolder == true
    }

    var canRemoveSelection: Bool { selected != nil }

    /// Words for a failure, chosen so the first thing a person reads tells them
    /// whether this is their problem or the agent's.
    static func explain(_ error: any Error) -> String {
        switch error {
        case SourceService.Failure.noAgent:
            "Photo-Go-Round's agent is not running, so there is nothing to ask."
        case SourceService.Failure.unreachable(let reason):
            "The agent published an address but did not answer: \(reason)"
        case SourceService.Failure.notFound(let paths):
            paths.count == 1
                ? "Not found: \(paths[0])"
                : "Not found, so none of them were added:\n" + paths.joined(separator: "\n")
        case SourceService.Failure.refused(_, let reason):
            reason
        case SourceService.Failure.unreadable:
            "The agent's answer could not be read."
        default:
            error.localizedDescription
        }
    }
}
