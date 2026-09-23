import Foundation

/// The album's name, beside its identifier.
///
/// A Photos source was a `PHAssetCollection` identifier and nothing else, so an
/// album that stopped resolving had no name to be shown by: the app fell back
/// to the identifier's last path component, and two renumbered albums appeared
/// on 2026-09-07 as "040, 040". The identifier stays the locator — it is the
/// identity every other rule matches on — and what the album is called, what
/// kind of collection it is, and which folders hold it are stored beside it.
/// All three are nullable and stay `NULL` for a folder or a file, whose path
/// names itself.
///
/// `folders` is a JSON array of folder names, outermost first, rather than a
/// joined string: a Photos folder may be called anything, including something
/// with a separator in it, and "exact or it is not a match" is the rule the
/// reconnect in `Missing Albums Plan.md` lives by.
enum SchemaV11 {
    static let sql = """
        ALTER TABLE source ADD COLUMN title TEXT;
        ALTER TABLE source ADD COLUMN collection_kind TEXT;
        ALTER TABLE source ADD COLUMN folders TEXT;
        """
}
