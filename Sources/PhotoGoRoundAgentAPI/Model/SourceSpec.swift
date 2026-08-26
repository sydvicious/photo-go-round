import Foundation

/// A source as the *user chose it*, and therefore the one piece of library state
/// that cannot be reconstructed from anything else.
///
/// This lives in `UserDefaults`, not in the database. Everything the database
/// holds about a source — the photos found inside it, when it was last
/// refreshed, whether it is currently reachable — is derived by looking, so
/// deleting the database throws away a cache. The path somebody typed is not
/// derivable from anything, so it lives with the preferences.
///
/// The `source` table is a projection of this list, reconciled at launch.
public struct SourceSpec: Sendable, Equatable, Hashable {
    public var kind: SourceKind
    /// The absolute path, `PHAssetCollection` id, or Google album id.
    public var locator: String
    /// Folder sources only.
    public var recursive: Bool
    /// Disabling keeps the source but drops its photos from the deck.
    public var enabled: Bool

    public init(kind: SourceKind, locator: String, recursive: Bool = false, enabled: Bool = true) {
        self.kind = kind
        // **One spelling, decided here.** The locator is the identity — removal,
        // reconciliation, and duplicate detection all match it as a bare string
        // — so a folder written one way and read another is two sources that
        // are really one. Normalising at construction means every path agrees
        // without any of them having to remember.
        // **A folder ends in a slash; nothing else does.** The locator is the
        // identity that preferences, reconciliation, and duplicate detection
        // all match on as a bare string, so it has to have exactly one
        // spelling — and for a folder the two spellings a picker and a command
        // line produce are different strings for the same directory.
        //
        // For a kind that is not a path the same argument gives the opposite
        // answer: one spelling means *the identifier exactly as the library
        // gave it*. A `PHAssetCollection` identifier with a slash appended
        // would be stored once and never again match what PhotoKit returns.
        self.locator = kind == .folder && !locator.hasSuffix("/") ? locator + "/" : locator
        self.recursive = recursive
        self.enabled = enabled
    }

    /// A folder, which is what `--add-folder` and `PGR_FOLDERS` produce.
    public static func folder(_ path: String, recursive: Bool = false) -> SourceSpec {
        SourceSpec(kind: .folder, locator: path, recursive: recursive)
    }

    // MARK: - Property-list form

    /// Stored as a dictionary rather than an encoded blob, so that a person can
    /// read it in `defaults read` and repair it in `defaults write` — which is
    /// the whole reason preferences are the durable store rather than a file we
    /// invented a format for.
    var propertyList: [String: Any] {
        ["kind": kind.rawValue, "locator": locator, "recursive": recursive, "enabled": enabled]
    }

    init?(propertyList: Any) {
        guard let dictionary = propertyList as? [String: Any],
            let locator = dictionary["locator"] as? String, !locator.isEmpty
        else { return nil }
        // Everything but the locator has a sensible answer when absent, because
        // a hand-written `defaults write` will leave things out.
        // Entries written before folders were normalised are stored without the
        // trailing slash; the initialiser puts it back, so an old plist and a
        // new one describe the same source rather than two.
        let kind = SourceKind((dictionary["kind"] as? String) ?? SourceKind.folder.rawValue)
        self.init(
            kind: kind,
            locator: locator,
            recursive: (dictionary["recursive"] as? Bool) ?? false,
            enabled: (dictionary["enabled"] as? Bool) ?? true
        )
    }
}
