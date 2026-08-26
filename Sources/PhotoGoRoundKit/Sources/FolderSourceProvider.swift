import Foundation
import PhotoGoRoundAgentAPI

/// A directory on disk, optionally walked recursively.
///
/// Photos inside a folder are recorded by their path **relative to the folder**,
/// which is the decision that makes surviving a rename cheap: recover the folder
/// and every photo inside it is recovered with it, in one update to one row —
/// no per-photo repair, and correct even for a folder holding fifty thousand
/// images.
public struct FolderSourceProvider: SourceProvider {
    public let kind = SourceKind.folder
    private let fileAccess: any FileAccess

    public init(fileAccess: any FileAccess = UnsandboxedFileAccess()) {
        self.fileAccess = fileAccess
    }

    public func enumerate(
        _ source: Source,
        into sink: (DiscoveredPhoto) async throws -> Void
    ) async throws -> SourceReachability {
        guard source.kind == kind else {
            throw SourceProviderError.wrongProvider(expected: kind, got: source.kind)
        }

        return try await fileAccess.withSourceURL(source, performing: { root in
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: root.path(percentEncoded: false), isDirectory: &isDirectory
                ), isDirectory.boolValue
            else {
                return .unavailable(reason: PathAvailability.unavailableReason(for: root))
            }

            // `.producesRelativePathURLs` is the whole reason this walk has no
            // path arithmetic in it. Without it the enumerator yields absolute
            // URLs and the relative identifier has to be recovered by stripping
            // a prefix — which sounds trivial and is not, because Foundation
            // resolves symlinks in the children it yields but not in the root
            // it was handed, so a source under `/var` produces children under
            // `/private/var` and no single prefix matches. With it, Foundation
            // reports what it descended through, which is what it knew all along.
            var options: FileManager.DirectoryEnumerationOptions = [
                .skipsHiddenFiles, .skipsPackageDescendants, .producesRelativePathURLs,
            ]
            if source.recursive != true {
                options.insert(.skipsSubdirectoryDescendants)
            }

            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: FileClassifier.resourceKeys,
                    options: options
                )
            else {
                return .unavailable(reason: "could not be read")
            }

            var classifier = FileClassifier(
                sourceIsUbiquitous: FileClassifier.isUbiquitous(root))
            let keySet = Set(FileClassifier.resourceKeys)
            // Counters, not collections. Nothing here grows with the library.
            var found = 0
            var skippedVideos = 0

            // No autoreleasepool here, and that is a result rather than an
            // oversight. This loop needed one when it built an absolute path
            // per file — `path(percentEncoded:)` mints an Objective-C temporary
            // and a tight Swift loop crosses no pool boundary, which cost 94 MB
            // across 80,000 files against 12 MB with a pool. Asking Foundation
            // for the relative path instead removed the allocation rather than
            // draining it: 12.4 MB unpooled against 12.5 MB pooled, and 0.3s
            // per 80,000 files cheaper. `URL` and `URLResourceValues` are Swift
            // structs and never needed a pool of their own.
            // `for case ... in enumerator` is unavailable from an async
            // context — `NSEnumerator`'s iterator is not safe to hold across a
            // suspension — so the walk pulls one object at a time itself. This
            // is what the for-in was doing underneath in any case, so the
            // allocation behaviour measured in the note above is unchanged.
            while let object = enumerator.nextObject() {
                guard let fileURL = object as? URL else { continue }
                let values = try? fileURL.resourceValues(forKeys: keySet)
                guard values?.isRegularFile == true else { continue }

                guard let mediaType = FileClassifier.mediaType(of: fileURL, values: values) else {
                    continue  // not media at all; no row, no trace
                }
                if mediaType == .video {
                    // Deliberately excluded, and counted rather than silently
                    // dropped — the difference between 2.0 being a feature and
                    // being an excavation.
                    skippedVideos += 1
                    continue
                }

                // Already relative to the source root, and already the exact
                // bytes the filesystem reported — verified against NFC and NFD
                // spellings of the same name, emoji, CJK, Arabic, stacked
                // combining marks, and a filename containing a newline, all of
                // which reopen by root-plus-this.
                let relative = fileURL.relativePath
                guard !relative.isEmpty else { continue }

                try await sink(
                    DiscoveredPhoto(
                        externalID: relative,
                        mediaType: mediaType,
                        storage: classifier.storage(of: fileURL, values: values),
                        byteSize: FileClassifier.byteSize(of: fileURL, values: values)
                    )
                )
                found += 1
            }

            Log.sources.info(
                "folder source \(source.id, privacy: .public) enumerated \(found, privacy: .public) images, skipped \(skippedVideos, privacy: .public) videos"
            )
            return .reachable
        })
    }

    public func materialize(
        externalID: String,
        from source: Source,
        to destination: URL
    ) async throws -> MaterializedFile {
        try fileAccess.withPhotoURL(in: source, externalID: externalID) { fileURL in
            try Self.copy(fileURL, to: destination, externalID: externalID)
        }
    }

    public func existence(of externalID: String, in source: Source) async -> PhotoExistence {
        // A photo inside a subfolder of a source that is no longer recursive is
        // *out of the source*, however healthily it sits on disk. Nothing else
        // notices: the walk simply stops yielding it, and the removal pass asks
        // this question rather than diffing against what the walk found — so
        // without this, turning the checkbox off left every nested photograph in
        // the pool for ever, still being dealt.
        if source.recursive != true, externalID.contains("/") { return .absent }
        return Self.fileExistence(of: externalID, in: source, using: fileAccess)
    }

    public func availability(of source: Source) async -> SourceAvailability {
        Self.fileAvailability(of: source, using: fileAccess)
    }

    /// The three states, for anything backed by a path — which is
    /// `PathAvailability.availability(of:)`, shared with every other caller that
    /// needs the same answer about the same path.
    static func fileAvailability(
        of source: Source, using fileAccess: any FileAccess
    ) -> SourceAvailability {
        do {
            return try fileAccess.withSourceURL(source) { PathAvailability.availability(of: $0) }
        } catch {
            // Could not even ask. That is not evidence of anything.
            return .offline(reason: String(describing: error))
        }
    }

    /// A `stat`, and — when it comes back negative — a second `stat` on the
    /// source itself.
    ///
    /// That second check is the entire difference between "you deleted this
    /// photo" and "your drive is not plugged in". Without it the two are
    /// indistinguishable, and treating them alike destroys a library on the
    /// first undock.
    static func fileExistence(
        of externalID: String,
        in source: Source,
        using fileAccess: any FileAccess
    ) -> PhotoExistence {
        do {
            let photoIsThere = try fileAccess.withPhotoURL(in: source, externalID: externalID) {
                FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
            }
            if photoIsThere { return .present }

            let sourceIsThere = try fileAccess.withSourceURL(source) {
                FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
            }
            guard sourceIsThere else {
                return .unknown(
                    reason: PathAvailability.unavailableReason(for: URL(filePath: source.locator)))
            }
            // The source is right there and the photo is not. It is gone.
            return .absent
        } catch {
            return .unknown(reason: String(describing: error))
        }
    }

    /// The path relative to the source's own folder, which is what goes in
    /// `external_id`.
    static func copy(_ fileURL: URL, to destination: URL, externalID: String) throws -> MaterializedFile {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            throw SourceProviderError.photoMissing(externalID: externalID)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Replacing rather than failing: a half-written cache entry from a
        // previous run should not wedge this photo for ever.
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: fileURL, to: destination)

        let size =
            (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return MaterializedFile(url: destination, byteSize: size)
    }
}

/// One explicitly chosen image file.
///
/// A first-class source kind rather than a folder with a single entry. Pinning
/// one photo and adding a folder of ten thousand are the same operation to the
/// deck.
public struct FileSourceProvider: SourceProvider {
    public let kind = SourceKind.file
    private let fileAccess: any FileAccess

    public init(fileAccess: any FileAccess = UnsandboxedFileAccess()) {
        self.fileAccess = fileAccess
    }

    public func enumerate(
        _ source: Source,
        into sink: (DiscoveredPhoto) async throws -> Void
    ) async throws -> SourceReachability {
        guard source.kind == kind else {
            throw SourceProviderError.wrongProvider(expected: kind, got: source.kind)
        }

        return try await fileAccess.withSourceURL(source, performing: { fileURL in
            let values = try? fileURL.resourceValues(forKeys: Set(FileClassifier.resourceKeys))
            guard values?.isRegularFile == true else {
                return .unavailable(reason: PathAvailability.unavailableReason(for: fileURL))
            }
            guard let mediaType = FileClassifier.mediaType(of: fileURL, values: values),
                mediaType == .image
            else {
                // The user pointed at something that is not a still image. That
                // is a mistake to report, not a source to keep rescanning.
                return .unavailable(reason: "not a still image")
            }

            var classifier = FileClassifier(
                sourceIsUbiquitous: FileClassifier.isUbiquitous(fileURL))
            try await sink(
                DiscoveredPhoto(
                    externalID: fileURL.lastPathComponent,
                    mediaType: mediaType,
                    storage: classifier.storage(of: fileURL, values: values),
                    byteSize: FileClassifier.byteSize(of: fileURL, values: values)
                )
            )
            return .reachable
        })
    }

    public func materialize(
        externalID: String,
        from source: Source,
        to destination: URL
    ) async throws -> MaterializedFile {
        try fileAccess.withPhotoURL(in: source, externalID: externalID) { fileURL in
            try FolderSourceProvider.copy(fileURL, to: destination, externalID: externalID)
        }
    }

    public func existence(of externalID: String, in source: Source) async -> PhotoExistence {
        // A file source's locator *is* the photo, so "is the source there" and
        // "is the photo there" are the same question — and a negative answer
        // cannot be attributed without knowing whether the volume is mounted.
        FolderSourceProvider.fileExistence(of: externalID, in: source, using: fileAccess)
    }

    /// The same question once more, and the same three answers: for a file
    /// source, the photograph going away *is* the source going away.
    public func availability(of source: Source) async -> SourceAvailability {
        FolderSourceProvider.fileAvailability(of: source, using: fileAccess)
    }
}
