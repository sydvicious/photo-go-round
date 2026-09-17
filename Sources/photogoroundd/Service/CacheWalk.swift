import Dispatch
import Foundation

/// Where the cache walk runs: its own thread, off everything else.
///
/// **Phase 6 of `Agent Performance Overhaul.md`.** The index the agent opens on
/// is what the database claimed; this is the check against the disk, and it is
/// thousands of `stat` calls — 8.9 s after a restart, 137 ms warm. On the shared
/// pool that would be the starvation the overhaul exists to remove, so it has a
/// queue of its own, like `Resizer`.
///
/// `utility`, not `userInitiated`: nobody is waiting for it. A request served
/// from a file the walk has not reached yet is served all the same.
actor CacheWalk {
    private let queue = DispatchSerialQueue(
        label: "com.sydpolk.photogoround.cache-walk", qos: .utility)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func run(_ work: @Sendable () -> Void) {
        work()
    }
}
