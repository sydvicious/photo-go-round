import Foundation
import PhotoGoRoundAgentAPI

/// A source somebody has asked for, before anything has checked whether it is
/// there.
///
/// The distinction from `SourceSpec` is the whole point: a spec is a source
/// that exists and has an identity, and this is a path somebody typed or picked
/// out of a dialog. Turning one into the other is where the path is resolved
/// and where the batch is refused if any of it is wrong.
public struct SourceRequest: Sendable, Equatable {
    public var kind: SourceKind
    public var path: String
    /// Folders only, and per folder — a flat directory and a nested tree can be
    /// asked for in one breath and each keeps its own answer.
    public var recursive: Bool

    public init(kind: SourceKind, path: String, recursive: Bool = false) {
        self.kind = kind
        self.path = path
        self.recursive = recursive
    }

    public static func folder(_ path: String, recursive: Bool = false) -> SourceRequest {
        SourceRequest(kind: .folder, path: path, recursive: recursive)
    }

    public static func file(_ path: String) -> SourceRequest {
        SourceRequest(kind: .file, path: path)
    }
}

extension SourceRequest {

    /// What a batch resolved to: every source, or every path that was wrong.
    public enum Resolution: Sendable, Equatable {
        case resolved([SourceSpec])
        case missing([String])
        /// Paths that exist but are not the kind they were asked for as — a
        /// file named as a folder, a directory named as a file. Accepted, such
        /// a source would sit in the library producing nothing, reading as
        /// broken, when the mistake was cheap to name at the door.
        case mismatched([String])
    }

    /// Resolves a batch, **all of it or none of it**.
    ///
    /// A command naming three folders where the second is misspelled should add
    /// none of them, rather than leaving the library in a state that depends on
    /// argument order. That rule used to live inside a `Console.failure` and an
    /// `ExitCode`, where the app could not reach it and no test could either.
    ///
    /// Every missing path is reported rather than only the first, because
    /// somebody fixing a typo would rather learn about all three at once than
    /// discover them one run at a time. Paths are standardized, so `~/x/../y`
    /// and a trailing slash do not become two different sources.
    ///
    /// Duplicates are *not* removed here. Whether a path is already a source is
    /// a question about the list it is being added to, and `addSources` answers
    /// it; this only answers whether the path is real.
    public static func resolve(
        _ requests: [SourceRequest], fileManager: FileManager = .default
    ) -> Resolution {
        var specs: [SourceSpec] = []
        var missing: [String] = []
        var mismatched: [String] = []

        for request in requests {
            // **A locator that is not a path resolves to itself.** Standardizing
            // it, `stat`ing it, and checking its directory-ness are all wrong
            // for a `PHAssetCollection` identifier, and appending a trailing
            // slash is actively harmful — it would be stored once and never
            // again match what the library returns. Whether such a locator
            // names anything is a question only a provider can answer, and
            // `SourceStore.add` asks it before this is called.
            guard request.kind.isFileBacked else {
                specs.append(SourceSpec(kind: request.kind, locator: request.path))
                continue
            }
            var resolved = URL(filePath: request.path).standardizedFileURL
                .path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
                missing.append(resolved)
                continue
            }
            guard isDirectory.boolValue == (request.kind != .file) else {
                mismatched.append(resolved)
                continue
            }
            // **A folder ends in a slash, always.** `NSOpenPanel` hands back a
            // directory URL and produces one; a path typed on a command line
            // usually does not — and the two spellings are different strings, so
            // the same folder can be listed twice and removing it by one
            // spelling leaves the other behind. The locator is the key that
            // preferences and the source table are matched on, so it has to have
            // exactly one form.
            if request.kind != .file, !resolved.hasSuffix("/") { resolved += "/" }
            specs.append(
                request.kind == .file
                    ? SourceSpec(kind: .file, locator: resolved)
                    : SourceSpec(kind: request.kind, locator: resolved, recursive: request.recursive)
            )
        }

        // Missing outranks mismatched when a batch has both: a path that is
        // not there at all is the likelier typo, and either way the whole
        // batch is refused.
        guard missing.isEmpty else { return .missing(missing) }
        guard mismatched.isEmpty else { return .mismatched(mismatched) }
        return .resolved(specs)
    }
}
