import Foundation
import PhotoGoRoundAgentAPI

/// Vends a usable `URL` for a source's item, for the duration of a closure.
///
/// This exists as insurance against the single most likely architectural
/// reversal in the project. The Mac runs unsandboxed today, which is what makes
/// arbitrary folder access, wallpaper setting, and cross-container cache writes
/// straightforward. But sandboxing may turn out to be forced rather than
/// chosen — by the Phase 8 widget, or by any future decision to ship through
/// the App Store — and if it is, every folder stops being a path and becomes a
/// security-scoped bookmark that must be resolved inside
/// `startAccessingSecurityScopedResource()` and released after.
///
/// So no call site ever constructs a `URL` from a stored path. Unsandboxed, the
/// implementation resolves a path and does nothing else. Sandboxed, it resolves
/// a bookmark, starts access, runs the closure, and stops access. Provider code
/// is identical either way, and the decision to sandbox becomes one
/// implementation swap rather than an archaeology expedition.
///
/// iOS needs the bookmark path regardless, since it has no equivalent of an
/// always-mounted internal volume and everything reachable through the document
/// picker can be evicted underneath us.
public protocol FileAccess: Sendable {
    /// Runs `body` with a URL for the source's own item — the folder, or the
    /// single file. The URL is valid only for the duration of the closure.
    func withSourceURL<T>(_ source: Source, _ body: (URL) throws -> T) throws -> T

    /// The same scope, for a body that suspends.
    ///
    /// **Enumeration needs this because its sink writes to the database.** A
    /// walk of a network folder streams thousands of photographs into batched
    /// transactions, and doing that synchronously from an async task parks a
    /// cooperative-pool thread on every contended batch — four concurrent walks
    /// were enough to leave nothing for serving to run on. See
    /// `Database.transaction`'s async form.
    /// A distinct label rather than an overload: a trailing closure drops its
    /// label, and the synchronous form then wins resolution even when the body
    /// plainly suspends.
    func withSourceURL<T>(
        _ source: Source,
        performing body: (URL) async throws -> T
    ) async throws -> T
}

extension FileAccess {
    /// Runs `body` with a URL for one photo inside a source, which for a folder
    /// source means resolving its stored relative path against the folder.
    ///
    /// Access is scoped to the source's item, so a single scope covers a whole
    /// tree rather than needing one per photo.
    public func withPhotoURL<T>(
        in source: Source,
        externalID: String,
        _ body: (URL) throws -> T
    ) throws -> T {
        try withSourceURL(source) { root in
            switch source.kind {
            case .file:
                // A file source's locator *is* the photo.
                return try body(root)
            default:
                return try body(root.appending(path: externalID))
            }
        }
    }
}

/// The Mac implementation while the agent runs unsandboxed: a path, and nothing
/// else to do.
public struct UnsandboxedFileAccess: FileAccess {
    public init() {}

    public func withSourceURL<T>(_ source: Source, _ body: (URL) throws -> T) throws -> T {
        guard source.kind.isFileBacked else {
            throw FileAccessError.notFileBacked(kind: source.kind)
        }
        return try body(URL(filePath: source.locator))
    }

    public func withSourceURL<T>(
        _ source: Source,
        performing body: (URL) async throws -> T
    ) async throws -> T {
        guard source.kind.isFileBacked else {
            throw FileAccessError.notFileBacked(kind: source.kind)
        }
        return try await body(URL(filePath: source.locator))
    }
}

public enum FileAccessError: Error, CustomStringConvertible, Sendable {
    case notFileBacked(kind: SourceKind)
    case couldNotResolveBookmark(sourceID: Int64)
    case accessDenied(path: String)

    public var description: String {
        switch self {
        case .notFileBacked(let kind):
            "source kind \(kind) has no file to access"
        case .couldNotResolveBookmark(let sourceID):
            "the bookmark for source \(sourceID) no longer resolves"
        case .accessDenied(let path):
            "access denied: \(path)"
        }
    }
}
