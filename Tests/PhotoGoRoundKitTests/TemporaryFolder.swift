import Foundation

/// A scratch directory that cleans itself up, with helpers for putting
/// plausible files in it.
final class TemporaryFolder {
    let url: URL

    init(name: String = "pgr-sources") {
        url = URL.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.standardizedFileURL.path(percentEncoded: false) }

    /// Writes a file with the given relative path, creating directories as
    /// needed. Contents are arbitrary — uniform type identifiers come from the
    /// extension, which is what the provider filters on.
    @discardableResult
    func write(_ relativePath: String, bytes: Int = 32) -> URL {
        let target = url.appending(path: relativePath)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: target.path(percentEncoded: false),
            contents: Data(repeating: 0xAB, count: bytes)
        )
        return target
    }

    func remove(_ relativePath: String) {
        try? FileManager.default.removeItem(at: url.appending(path: relativePath))
    }

    func subfolder(_ name: String) -> URL {
        let target = url.appending(path: name)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
}
