import Foundation
import PhotoGoRoundAgentAPI

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
public final class LibraryChanges: @unchecked Sendable {

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

    private let lock = NSLock()
    private var recording: Bool
    private var counts: [Int64: Count] = [:]
    /// What each source removed since launch was called, since its row is gone
    /// and nothing else will know.
    private var removedNames: [Int64: String] = [:]

    public init(recording: Bool = false) {
        self.recording = recording
    }

    public func startRecording() {
        lock.lock()
        recording = true
        lock.unlock()
    }

    public func added(_ count: Int, toSource source: Int64) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        counts[source, default: Count()].added += count
    }

    public func removed(_ count: Int, fromSource source: Int64) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        counts[source, default: Count()].removed += count
    }

    /// A whole source gone, with the photographs it held.
    public func sourceRemoved(_ source: Source, photos: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        removedNames[source.id] = source.spokenName
        if photos > 0 { counts[source.id, default: Count()].removed += photos }
    }

    /// Every source that has added or removed anything since launch.
    public var bySource: [Int64: Count] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// What a source removed since launch was called when it went.
    public func nameOfRemovedSource(_ id: Int64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return removedNames[id]
    }
}
