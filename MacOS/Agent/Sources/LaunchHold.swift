import Foundation

/// Holds the launch's refresh and cache walk until the first picture has gone
/// out, so a restart serves from what it already has before anything competes
/// with it for the disk.
///
/// **Why.** A restart's first picture waits for nothing but the queue — the
/// refresh and the walk both run behind the open port. But they run *beside*
/// it, on the same disk and the same writer. At the 22:23 boot on 2026-09-23
/// the wallpaper's first picture took 10.7 s, about 7.4 s of it the agent's own
/// database work contending with the two of them. Syd, 2026-09-24: "when the
/// agent starts up, it should be ready to serve images already if it has been
/// running before, even before the refresh is done". `Plans/Startup
/// Performance.md`.
///
/// **Opened once, by whichever comes first:** a picture delivered; a request
/// that found the deck empty, since then only a refresh can help; an empty
/// queue at launch, for the same reason; or `limit` after the port opened, so
/// an agent nobody asks still refreshes. After that it never holds anything
/// again.
actor LaunchHold {
    /// Why the hold opened, for the one line it leaves.
    enum Reason: String, Sendable {
        case delivered = "a picture was delivered"
        case emptyDeck = "the deck came up empty"
        case nothingQueued = "nothing was queued"
        case timedOut = "nothing was asked for"
        case notServing = "the run does not serve"
    }

    /// How long the launch's refresh and walk wait for a first picture.
    ///
    /// **Thirty seconds, Syd's cap.** At the 22:40 boot the screensaver's first
    /// fresh picture came 7 s after the port opened, and at 22:23 the
    /// wallpaper asked about 16 s after. The Photos albums take 40 to 60 s at
    /// boot whatever happens, so they finish up to this much later.
    static let limit: Duration = .seconds(30)

    private let began: ContinuousClock.Instant
    private(set) var opened: Reason?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(at began: ContinuousClock.Instant = .now) {
        self.began = began
    }

    /// Opens the hold, unless it is already open. Answers whether this call
    /// opened it, so the caller that did can say so.
    @discardableResult
    func open(because reason: Reason) -> Bool {
        guard opened == nil else { return false }
        opened = reason
        for continuation in waiting { continuation.resume() }
        waiting = []
        return true
    }

    /// How long the hold was shut, from launch to `open`.
    func heldFor(at now: ContinuousClock.Instant = .now) -> Duration {
        now - began
    }

    /// How many are waiting, so a test can see a waiter parked.
    var waitingCount: Int { waiting.count }

    /// Returns once the hold is open.
    func wait() async {
        guard opened == nil else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Opens after `limit` if nothing has opened it first.
    nonisolated func openAfter(_ limit: Duration, then said: @escaping @Sendable (Reason, Duration) -> Void) {
        Task {
            try? await Task.sleep(for: limit)
            if await open(because: .timedOut) { said(.timedOut, await heldFor()) }
        }
    }
}
