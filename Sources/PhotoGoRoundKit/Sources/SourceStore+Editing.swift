import Foundation

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
        /// A kind with no provider — a Photos album, today. It would be
        /// accepted, never scanned, and reported unavailable forever.
        case unsupportedKind(SourceKind)
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
    ) throws -> Addition {
        // The write and the reconcile are one act — see `SourceStore.editing`.
        Self.editing.lock()
        defer { Self.editing.unlock() }

        if let unsupported = requests.first(where: { !$0.kind.isFileBacked })?.kind {
            throw EditFailure.unsupportedKind(unsupported)
        }
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
            specs = resolved
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
