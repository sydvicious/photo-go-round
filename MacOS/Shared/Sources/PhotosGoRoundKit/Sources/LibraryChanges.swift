import Foundation
import PhotosGoRoundAgentAPI

/// Photographs added to and removed from the library since the agent launched,
/// by source. Asked for by Syd on 2026-09-13, for the dashboard's photos panel.
///
/// **Counted where rows are written, not where a change is noticed.** A
/// photograph enters the `photo` table one way, a refresh's upsert, and leaves
/// it three: a refresh that no longer finds it, a fetch or a serve whose source
/// confirms it gone, and its source being removed. The first two all go through
/// `PhotoPool`, the third is a cascade from `SourceStore.remove(id:)`, and those
/// are where this is told — so a new way of noticing a change is counted without
/// anyone remembering to.
///
/// **Told after the transaction commits**, so a batch that rolled back is not
/// counted. A photograph already in the library through another source is not
/// added, because its row is not written.
///
/// **Nothing is recorded until `startRecording`**, and only the agent calls it.
/// `pgr_ctl` writes the same tables from another process and is not seen here.
///
/// In memory and gone at exit.
public actor LibraryChanges {

    public struct Count: Sendable, Equatable {
        public var added: Int
        public var removed: Int

        public init(added: Int = 0, removed: Int = 0) {
            self.added = added
            self.removed = removed
        }
    }

    /// The agent's record. A process that never starts recording leaves it empty.
    public static let shared = LibraryChanges()

    private var recording: Bool
    private var counts: [Int64: Count] = [:]
    /// What each source removed since launch was called, since its row is gone
    /// and nothing else will know.
    private var removedNames: [Int64: String] = [:]

    /// What a reporter hands over, and what the drain applies.
    ///
    /// **An `AsyncStream`, as the other two ledgers have.** Syd, 2026-09-17:
    /// "AsyncStream for LibraryChanges too". Nothing a refresh does next reads
    /// these counts back — they are for the dashboard — so a page of a hundred
    /// reports what it did and carries on. `Continuation.yield` never suspends
    /// and keeps the order the pages were applied in, which a `Task` per page
    /// would not.
    private enum Report: Sendable {
        case started
        case added(count: Int, source: Int64)
        case removed(count: Int, source: Int64)
        case sourceRemoved(id: Int64, name: String, photos: Int)
        /// A caller waiting for everything ahead of it to have been applied.
        case barrier(CheckedContinuation<Void, Never>)
    }

    private nonisolated let inbox: AsyncStream<Report>
    private nonisolated let post: AsyncStream<Report>.Continuation

    public init(recording: Bool = false) {
        self.recording = recording
        (inbox, post) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        Task { await self.drain() }
    }

    private func drain() async {
        for await report in inbox {
            switch report {
            case .started: recording = true
            case .added(let count, let source):
                guard recording, count > 0 else { continue }
                counts[source, default: Count()].added += count
            case .removed(let count, let source):
                guard recording, count > 0 else { continue }
                counts[source, default: Count()].removed += count
            case .sourceRemoved(let id, let name, let photos):
                guard recording else { continue }
                removedNames[id] = name
                if photos > 0 { counts[id, default: Count()].removed += photos }
            case .barrier(let continuation): continuation.resume()
            }
        }
    }

    /// Waits until everything reported before this call has been counted.
    ///
    /// The reports go through a queue, so a caller that records and then reads
    /// would otherwise be racing the drain. This puts itself in the same queue
    /// and waits its turn.
    public nonisolated func settle() async {
        await withCheckedContinuation { continuation in post.yield(.barrier(continuation)) }
    }

    public nonisolated func startRecording() {
        post.yield(.started)
    }

    public nonisolated func added(_ count: Int, toSource source: Int64) {
        post.yield(.added(count: count, source: source))
    }

    public nonisolated func removed(_ count: Int, fromSource source: Int64) {
        post.yield(.removed(count: count, source: source))
    }

    /// A whole source gone, with the photographs it held.
    public nonisolated func sourceRemoved(_ source: Source, photos: Int) {
        post.yield(
            .sourceRemoved(id: source.id, name: source.spokenName, photos: photos))
    }

    /// Every source that has added or removed anything since launch.
    public var bySource: [Int64: Count] {
        return counts
    }

    /// What a source removed since launch was called when it went.
    public func nameOfRemovedSource(_ id: Int64) -> String? {
        return removedNames[id]
    }
}
