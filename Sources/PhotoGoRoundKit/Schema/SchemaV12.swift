import Foundation

/// The name Photos imported a photograph with, beside its identifier.
///
/// A Photos photograph's `external_id` is a `PHAsset` identifier, so every line
/// that named one — served, fetched, dropped — named `C3D4…/L0/001`, and the
/// dashboard had to ask Photos for the filename while somebody was looking.
///
/// **Written when the original is fetched**, because that is when the provider
/// already holds the asset's resources: the name costs nothing there and a
/// round trip anywhere else. `NULL` for a folder or a file, whose path names
/// itself, and for a Photos photograph not fetched since this migration.
enum SchemaV12 {
    static let sql = """
        ALTER TABLE photo ADD COLUMN original_filename TEXT;
        """
}
