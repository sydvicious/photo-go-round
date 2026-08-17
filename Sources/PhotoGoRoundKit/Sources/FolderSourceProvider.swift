import Foundation

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

    public func enumerate(_ source: Source) async throws -> SourceEnumeration {
        guard source.kind == kind else {
            throw SourceProviderError.wrongProvider(expected: kind, got: source.kind)
        }

        return try fileAccess.withSourceURL(source) { root in
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: root.path(percentEncoded: false), isDirectory: &isDirectory
                ), isDirectory.boolValue
            else {
                return .unavailable(FileClassifier.unavailableReason(for: root))
            }

            var options: FileManager.DirectoryEnumerationOptions = [
                .skipsHiddenFiles, .skipsPackageDescendants,
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
                return .unavailable("could not be read")
            }

            let rootPath = root.standardizedFileURL.path(percentEncoded: false)
            var classifier = FileClassifier()
            var photos: [DiscoveredPhoto] = []
            var skippedVideos = 0

            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: Set(FileClassifier.resourceKeys))
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

                guard let relative = Self.relativePath(of: fileURL, under: rootPath) else { continue }

                photos.append(
                    DiscoveredPhoto(
                        externalID: relative,
                        mediaType: mediaType,
                        storage: classifier.storage(of: fileURL, values: values),
                        byteSize: FileClassifier.byteSize(of: fileURL, values: values)
                    )
                )
            }

            Log.sources.info(
                "folder source \(source.id, privacy: .public) enumerated \(photos.count, privacy: .public) images, skipped \(skippedVideos, privacy: .public) videos"
            )
            return SourceEnumeration(photos: photos)
        }
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

    /// The path relative to the source's own folder, which is what goes in
    /// `external_id`.
    static func relativePath(of fileURL: URL, under rootPath: String) -> String? {
        let path = fileURL.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    static func copy(_ fileURL: URL, to destination: URL, externalID: String) throws -> MaterializedFile {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            throw SourceProviderError.photoMissing(externalID: externalID)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Replacing rather than failing: a half-written cache entry from a
        // previous run should not wedge the prefetcher for ever.
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

    public func enumerate(_ source: Source) async throws -> SourceEnumeration {
        guard source.kind == kind else {
            throw SourceProviderError.wrongProvider(expected: kind, got: source.kind)
        }

        return try fileAccess.withSourceURL(source) { fileURL in
            let values = try? fileURL.resourceValues(forKeys: Set(FileClassifier.resourceKeys))
            guard values?.isRegularFile == true else {
                return .unavailable(FileClassifier.unavailableReason(for: fileURL))
            }
            guard let mediaType = FileClassifier.mediaType(of: fileURL, values: values),
                mediaType == .image
            else {
                // The user pointed at something that is not a still image. That
                // is a mistake to report, not a source to keep rescanning.
                return .unavailable("not a still image")
            }

            var classifier = FileClassifier()
            return SourceEnumeration(photos: [
                DiscoveredPhoto(
                    externalID: fileURL.lastPathComponent,
                    mediaType: mediaType,
                    storage: classifier.storage(of: fileURL, values: values),
                    byteSize: FileClassifier.byteSize(of: fileURL, values: values)
                )
            ])
        }
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
}
