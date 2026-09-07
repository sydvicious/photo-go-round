import Foundation
import PhotoGoRoundAgentAPI

/// Adding and removing a source, which is a write to *preferences* followed by
/// a reconcile — never a write to the `source` table.
///
/// **This is the plumbing, and everything that edits a source list runs on it.**
/// `pgr_ctl` calls it with the agent stopped, the service calls it on behalf of
/// a client that asked over HTTP, and neither owns a second copy of the rule.
/// The rule is worth stating once here rather than in each of them:
///
/// The table is a projection of the durable list, so a row written straight into
/// the database is deleted again at the agent's next reconcile and a row
/// disabled there is re-enabled just as fast. Writing to preferences and
/// reconciling in the same breath is the only version of this that survives a
/// running agent, and it is also the version that works when nothing is running
/// at all.
///
/// **Refreshing is deliberately not here.** `pgr_ctl` scans a new source inline
/// because adding one is the moment somebody is watching; the service answers
/// before the scan, because a folder of eight thousand photographs takes seconds
/// to walk and a request that blocked on it would look like a hang. Same write,
/// two different things to do next.
extension SourceStore {

    /// What went wrong before anything was written. Every case leaves the
    /// library exactly as it was.
    public enum EditFailure: Error, Sendable, Equatable {
        /// A kind with no provider registered. It would be accepted, never
        /// scanned, and reported unavailable forever.
        ///
        /// **The question is "is there a provider", not "is it a path".** It
        /// used to be the latter, which was the same answer while every kind
        /// was file-backed and the wrong one the moment a Photos album could
        /// be added.
        case unsupportedKind(SourceKind)
        /// Locators that are not paths and did not resolve — an album
        /// identifier naming nothing in this Photos library, or a library that
        /// cannot be read at all. Refused under the same all-or-none rule as a
        /// mistyped path, and naming itself.
        case locatorsNotFound([String])
        /// A reconnect asked of a source that is not a missing album: a
        /// folder, an album that is there, or one behind a permission prompt.
        /// Only an album the library cannot find has a successor to look for.
        case notMissing
        /// A reconnect that found no album, or more than one, called what
        /// this one was and sitting where it sat. The titles of whatever it
        /// did find, so a person can see why. The source stays missing.
        case notReconnectable(matches: [String])
        /// Paths that are not there. **All of them, and the whole batch is
        /// refused**: a request naming three folders where the second is
        /// misspelled adds none of them, rather than leaving the library in a
        /// state that depends on the order they were given in.
        case pathsNotFound([String])
        /// Paths that exist but are not the kind they were asked for as — a
        /// file named as a folder, a directory named as a file. Refused with
        /// the same all-or-none rule, because such a source would be accepted,
        /// produce nothing, and read as broken.
        case pathsNotOfKind([String])
        /// An option this kind of source does not have — recursion on a single
        /// file. Refused rather than stored, because a source table that holds
        /// answers to questions its kind cannot be asked is a table nobody can
        /// read confidently afterwards.
        case optionNotAvailable(option: String, kind: SourceKind)
        /// Written to preferences, and the reconcile did not produce a row. Not
        /// reachable by anything a caller did wrong; it means the projection is
        /// broken, which is worth saying rather than returning a short list.
        case notProjected(String)
    }

    /// What adding a batch did.
    public struct Addition: Sendable, Equatable {
        /// The rows created, in the order they were asked for. These carry the
        /// `uuid` a client names a source by and the `id` `pgr_ctl` prints.
        public let added: [Source]
        /// Locators that were already sources. Not an error — it is what makes
        /// re-asserting the same list a no-op rather than a duplicate.
        public let alreadyListed: [String]

        public var isEmpty: Bool { added.isEmpty }
    }

    /// Resolves a batch, writes it to preferences, and brings the table into
    /// step — **one write and therefore one doorbell**, because a two-hundred-file
    /// selection added one at a time would ask the agent to refresh two hundred
    /// times.
    @discardableResult
    public func add(
        _ requests: [SourceRequest], to preferences: Preferences,
        fileManager: FileManager = .default, now: Date = Date()
    ) async throws -> Addition {
        // **Asked before the lock is taken, and that is not tidiness.**
        // Validating a locator that is not a path means asking a provider,
        // which suspends, and `editing` is an `NSLock` — holding one across an
        // await is unavailable in an async context for good reason. Nothing
        // here writes, so there is nothing to guard yet.
        if let unsupported = requests.first(where: { provider(for: $0.kind) == nil })?.kind {
            throw EditFailure.unsupportedKind(unsupported)
        }
        let resolution = await resolveLocators(in: requests, now: now)
        guard resolution.unresolved.isEmpty else {
            throw EditFailure.locatorsNotFound(resolution.unresolved)
        }

        return try write(
            requests, describedAs: resolution.descriptions, to: preferences,
            fileManager: fileManager, now: now)
    }

    /// How long adding will question a library about an album before it stops
    /// asking and records it anyway.
    ///
    /// **Short, because nothing here has to succeed.** Both questions below are
    /// asked to make the answer better, not to make the write correct: the scan
    /// establishes availability on its own and rewrites the description whenever
    /// it changes. Spending the library's own ten-second bound twice per album
    /// is what made a client give up on a `POST` the agent went on to complete.
    static let validationLimit = Duration.seconds(5)

    /// Which of the non-path locators the library says are not there — and, for
    /// the rest, what they are called.
    ///
    /// **A library that answers is believed; a library that does not is not
    /// guessed at. Changed 2026-09-07.** This used to require `.available` and
    /// reject everything else, which was right when every alternative to
    /// *available* was an answer. It is not any more: a library that has stopped
    /// answering reaches the provider as `.offline` too, and refusing on that
    /// told somebody an album they had just picked out of a list did not exist.
    ///
    /// So the three cases are kept apart:
    ///
    /// - **The library answered and the album is not there** — `.missing`,
    ///   `.gone` — refused, as before.
    /// - **The library answered and cannot be read at all** — a denial, which is
    ///   `.offline` — refused, as before. Accepting an album nobody may look at
    ///   would store a source reported unavailable for ever, and the person can
    ///   see why and fix it in System Settings.
    /// - **The library did not answer** — `nil` from `asking` below — recorded.
    ///   Nothing was said about this album, so nothing is concluded about it.
    ///   The source is unavailable with the reason on it until a scan succeeds,
    ///   which the refresh pass retries on its own for as long as it takes.
    ///
    /// The third case is only distinguishable from the second because
    /// `validationLimit` is **below** the library's own bound: a library that
    /// will not answer expires here first, rather than arriving as a fast
    /// `.offline` that reads like a refusal. `aSilentLibraryRecordsTheSource`
    /// is what holds that true.
    ///
    /// **The description is captured here, in the same breath**, because this
    /// is the one moment the agent is already asking the library about the
    /// album, and the client sending a name it looked up itself would be a
    /// second writer for one fact. It is not required: `refresh` writes the
    /// description whenever it differs, so a name missed here arrives with the
    /// first scan that works. See `Missing Albums Plan.md`, Phase 3.
    private func resolveLocators(
        in requests: [SourceRequest], now: Date
    ) async -> (unresolved: [String], descriptions: [String: SourceDescription]) {
        var bad: [String] = []
        var descriptions: [String: SourceDescription] = [:]
        // **A library that went quiet once is not asked again for this batch.**
        // The picker adds every ticked album in one request, so twenty albums
        // against a library that answers nothing would otherwise spend the bound
        // twenty times over and put the whole `POST` far past any client's
        // patience. The first silence is the answer for all of them: nothing is
        // known about any, and all are recorded.
        var silent: Set<SourceKind> = []

        for request in requests where !request.kind.isFileBacked {
            guard let provider = provider(for: request.kind) else { continue }
            guard !silent.contains(request.kind) else { continue }
            let provisional = Source(
                id: 0, uuid: "", kind: request.kind, locator: request.path, addedAt: now)

            // Nil is the library not answering inside the bound, which is not a
            // statement about the album and must not read as one.
            let standing = await Self.asking(within: Self.validationLimit) {
                await provider.availability(of: provisional)
            }
            switch standing {
            // The library answered, and the answer was no.
            case .missing, .gone, .offline:
                bad.append(request.path)
                continue
            case .available:
                break
            // `.none` is the library saying nothing, which is not a no.
            case .none:
                silent.insert(request.kind)
                continue
            }

            // Only worth asking of a library that just answered the question
            // before it. One that did not will not name the album either, and
            // the refresh writes the name in with the first scan that works.
            let described = await Self.asking(within: Self.validationLimit) {
                await provider.describe(provisional)
            }
            if let description = described.flatMap({ $0 }) {
                descriptions[request.path] = description
            } else if described == nil {
                silent.insert(request.kind)
            }
        }
        return (bad, descriptions)
    }

    /// Asks one question against a bound, and answers nil when it goes
    /// unanswered.
    ///
    /// The providers' own questions do not throw — they answer `.offline`,
    /// `nil`, `[]` — so the bound has to be applied from outside to tell *the
    /// library said so* from *nobody said anything*.
    private static func asking<T: Sendable>(
        within limit: Duration, _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        try? await Deadline.run(within: limit, work)
    }

    /// The part that writes, and therefore the part that holds the lock.
    private func write(
        _ requests: [SourceRequest], describedAs descriptions: [String: SourceDescription] = [:],
        to preferences: Preferences,
        fileManager: FileManager, now: Date
    ) throws -> Addition {
        // The write and the reconcile are one act — see `SourceStore.editing`.
        Self.editing.lock()
        defer { Self.editing.unlock() }

        // The same refusal `setRecursive` gives, so the two verbs agree that a
        // file has no such option — dropping it silently here would store a
        // source that PATCH then claims cannot be configured that way.
        if let optioned = requests.first(where: { $0.kind != .folder && $0.recursive }) {
            throw EditFailure.optionNotAvailable(option: "recursive", kind: optioned.kind)
        }

        let specs: [SourceSpec]
        switch SourceRequest.resolve(requests, fileManager: fileManager) {
        case .missing(let paths):
            throw EditFailure.pathsNotFound(paths)
        case .mismatched(let paths):
            throw EditFailure.pathsNotOfKind(paths)
        case .resolved(let resolved):
            specs = resolved.map { spec in
                var described = spec
                described.description = descriptions[spec.locator]
                return described
            }
        }

        let added = preferences.addSources(specs)
        try reconcile(with: preferences, now: now)

        let rows = try all()
        var created: [Source] = []
        for spec in added {
            guard let row = rows.first(where: { $0.locator == spec.locator }) else {
                throw EditFailure.notProjected(spec.locator)
            }
            created.append(row)
        }

        let new = Set(added.map(\.locator))
        return Addition(
            added: created,
            alreadyListed: specs.map(\.locator).filter { !new.contains($0) }
        )
    }

    /// Changes what a source was configured with, and returns it as it now
    /// stands.
    ///
    /// **Recursion is the only option today**, and it is deliberately not a
    /// remove-and-re-add: that would mint a new `uuid`, orphan the cache
    /// directory named by the old one, and throw away everything the deck knew
    /// about those photographs — for a checkbox.
    ///
    /// Turning it off is a real removal, and the pool notices at the next
    /// refresh rather than here: `FolderSourceProvider.existence` reports a
    /// nested photograph as absent once its source is no longer recursive, so
    /// the ordinary removal walk takes them out. Turning it on adds nothing
    /// until that same refresh finds the nested files.
    @discardableResult
    public func setRecursive(
        _ recursive: Bool, for source: Source, in preferences: Preferences, now: Date = Date()
    ) throws -> Source {
        guard source.kind == .folder else {
            throw EditFailure.optionNotAvailable(option: "recursive", kind: source.kind)
        }
        Self.editing.lock()
        defer { Self.editing.unlock() }
        guard preferences.setSourceRecursive(recursive, locator: source.locator) else {
            throw EditFailure.notProjected(source.locator)
        }
        try reconcile(with: preferences, now: now)
        guard let updated = try self.source(uuid: source.uuid) else {
            throw EditFailure.notProjected(source.locator)
        }
        return updated
    }

    /// Points a missing album at the one album in the library now that it was
    /// called and where it sat, keeping the source — its `uuid`, its cache
    /// directory, its enabled state, its place in the list.
    ///
    /// **The row and the preference change in one locked step.** Reconcile
    /// matches rows to preferences by locator; a preference pointing at the
    /// new identifier beside a row still holding the old would make the next
    /// reconcile remove the row, its photographs, and its cached bytes, and
    /// add a stranger. The lock keeps a reconcile from running between the two
    /// writes, and the preference goes first because it is the write that can
    /// refuse — the old locator not listed, the new one already there — and
    /// refusing before anything else has moved is cheaper than moving it back.
    ///
    /// The next refresh does the rest: the old rows name assets a rebuild
    /// renumbered too, so they leave and the album's photographs arrive under
    /// their new identifiers. What this saves the person is finding the album
    /// again among three hundred in the picker; see `Missing Albums Plan.md`.
    @discardableResult
    public func reconnect(
        _ source: Source, in preferences: Preferences, now: Date = Date()
    ) async throws -> Source {
        // Asked before the lock, like `add`: a provider suspends, and the lock
        // cannot be held across a suspension. Nothing here writes yet.
        guard let provider = provider(for: source.kind) else {
            throw EditFailure.unsupportedKind(source.kind)
        }
        guard case .missing = await provider.availability(of: source) else {
            throw EditFailure.notMissing
        }
        let matches = await provider.successors(of: source)
        guard matches.count == 1, let match = matches.first else {
            throw EditFailure.notReconnectable(matches: matches.map(\.description.title))
        }
        return try move(source, to: match, in: preferences)
    }

    /// The part of `reconnect` that writes, and therefore the part that holds
    /// the lock — synchronous, because `NSLock` is unavailable from an async
    /// context, and everything that had to suspend has already happened.
    private func move(
        _ source: Source, to match: SourceMatch, in preferences: Preferences
    ) throws -> Source {
        Self.editing.lock()
        defer { Self.editing.unlock() }
        guard
            preferences.replaceSource(
                locator: source.locator, with: match.locator, description: match.description)
        else { throw EditFailure.notProjected(source.locator) }
        do {
            try relocate(sourceID: source.id, to: match.locator, describedAs: match.description)
        } catch {
            // The preference moved and the row did not: put the preference
            // back, so the two still agree and the next reconcile is a no-op.
            preferences.replaceSource(
                locator: match.locator, with: source.locator, description: source.description)
            throw error
        }
        Log.sources.notice(
            "source \(source.id, privacy: .public) reconnected: \(source.locator, privacy: .public) is now \(match.locator, privacy: .public)"
        )
        guard let updated = try self.source(uuid: source.uuid) else {
            throw EditFailure.notProjected(match.locator)
        }
        return updated
    }

    /// Drops a source from the durable list, and with it the row, its
    /// photographs, and their queue entries.
    ///
    /// **Preferences key on the locator** rather than on either identifier: the
    /// locator is what the user chose and what `reconcile` matches on. A caller
    /// finds the source however it names one — `pgr_ctl` by row id, a client by
    /// `uuid` — and hands the row here.
    ///
    /// Removal is not deletion: **nothing on the source is touched**, only the
    /// library's knowledge of it. Reconciling deletes the row even for a source
    /// that was never in preferences, which is the state a hand-written row
    /// leaves behind.
    ///
    /// The photographs go by cascade and **their cached bytes go with them**,
    /// which is what this returns. That is a change of behaviour: they used to
    /// survive until the next launch rebuilt the byte index from the filesystem
    /// and discarded whatever the database no longer claimed, so removing a
    /// large source freed nothing until the agent was restarted.
    @discardableResult
    public func remove(
        _ source: Source, from preferences: Preferences, now: Date = Date()
    ) throws -> Int64 {
        // Removing from the durable list and projecting that removal are one
        // act. Apart, a reconcile already under way with the list as it was puts
        // the source straight back — see `SourceStore.editing`.
        Self.editing.lock()
        defer { Self.editing.unlock() }
        preferences.removeSource(locator: source.locator)
        return try reconcile(with: preferences, now: now).bytesFreed
    }
}
