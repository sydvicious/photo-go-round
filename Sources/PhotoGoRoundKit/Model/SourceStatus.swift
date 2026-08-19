import Foundation

/// What the agent found in a source, published where anything can read it.
///
/// **This is derived state living in preferences, which is deliberate and is
/// the exception rather than the rule.** The database is private to the service
/// — it is an implementation detail that may be replaced — so a claim another
/// process needs is *published* rather than queried. `servicePort` established
/// the pattern; this follows it.
///
/// Two properties come with that and are worth holding on to. A published value
/// **outlives the process that wrote it**, so a crashed agent leaves the last
/// counts behind exactly as it leaves a stale address — which is why `scannedAt`
/// is here. And it is disposable: deleting this key costs nothing but a wait
/// until the next scan.
public struct SourceStatus: Sendable, Equatable {
    /// The join key. Preferences address a source by locator, because that is
    /// the thing the user actually chose and what `reconcile` matches on.
    public let locator: String
    /// `Source.uuid` — the source's identity in the database, carried outward
    /// so a client can name a source in a log, or line one up against
    /// `pgr_ctl sources list`, without opening anything.
    public let uuid: String
    public let photoCount: Int
    public let available: Bool
    public let unavailableReason: String?
    /// When the count was established, not when it was copied here. Nil means
    /// the source has never been scanned, which is how a folder added a moment
    /// ago is told apart from one that scanned to nothing.
    public let scannedAt: Date?

    public init(
        locator: String,
        uuid: String,
        photoCount: Int,
        available: Bool,
        unavailableReason: String? = nil,
        scannedAt: Date? = nil
    ) {
        self.locator = locator
        self.uuid = uuid
        self.photoCount = photoCount
        self.available = available
        self.unavailableReason = unavailableReason
        self.scannedAt = scannedAt
    }

    /// A dictionary rather than an encoded blob, for the same reason
    /// `SourceSpec` is one: somebody can read it in `defaults read` and see
    /// what the agent believes.
    var propertyList: [String: Any] {
        var entry: [String: Any] = [
            "locator": locator,
            "uuid": uuid,
            "photoCount": photoCount,
            "available": available,
        ]
        if let unavailableReason { entry["unavailableReason"] = unavailableReason }
        if let scannedAt { entry["scannedAt"] = scannedAt }
        return entry
    }

    init?(propertyList: Any) {
        guard let dictionary = propertyList as? [String: Any],
            let locator = dictionary["locator"] as? String, !locator.isEmpty
        else { return nil }
        self.init(
            locator: locator,
            uuid: (dictionary["uuid"] as? String) ?? "",
            photoCount: (dictionary["photoCount"] as? Int) ?? 0,
            // Absent reads as available: a status written by a build that did
            // not have this field should not make every source look broken.
            available: (dictionary["available"] as? Bool) ?? true,
            unavailableReason: dictionary["unavailableReason"] as? String,
            scannedAt: dictionary["scannedAt"] as? Date
        )
    }
}
