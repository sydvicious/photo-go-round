import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Resolving what somebody asked for")
struct SourceRequestTests {

    private func makeFolder() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "pgr-request-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A folder that is there resolves to a source")
    func folderResolves() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        guard case .resolved(let specs) = SourceRequest.resolve([.folder(folder.path, recursive: true)])
        else {
            Issue.record("expected it to resolve")
            return
        }
        #expect(specs.count == 1)
        #expect(specs[0].kind == .folder)
        #expect(specs[0].recursive)
    }

    @Test("A file resolves to a file source, whatever recursion was asked for")
    func fileResolves() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "one.jpg")
        try Data([0]).write(to: file)

        guard case .resolved(let specs) = SourceRequest.resolve([.file(file.path)])
        else {
            Issue.record("expected it to resolve")
            return
        }
        #expect(specs[0].kind == .file)
        #expect(!specs[0].recursive)
    }

    /// The rule that used to live in a `Console.failure`: a batch naming three
    /// folders with one misspelled adds none of them, rather than leaving the
    /// library in a state that depends on argument order.
    @Test("One bad path refuses the whole batch")
    func oneBadPathRefusesEverything() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let resolution = SourceRequest.resolve([
            .folder(folder.path),
            .folder("/nowhere/at/all"),
        ])
        guard case .missing(let paths) = resolution else {
            Issue.record("expected it to refuse")
            return
        }
        #expect(paths == ["/nowhere/at/all"])
    }

    /// All of them, not just the first — somebody fixing typos would rather
    /// learn about three at once than one run at a time.
    @Test("Every missing path is reported, not only the first")
    func everyMissingPathIsReported() {
        let resolution = SourceRequest.resolve([
            .folder("/nowhere/one"), .folder("/nowhere/two"), .file("/nowhere/three"),
        ])
        guard case .missing(let paths) = resolution else {
            Issue.record("expected it to refuse")
            return
        }
        #expect(paths.count == 3)
    }

    @Test("Paths are standardized, so one folder cannot become two sources")
    func pathsAreStandardized() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let awkward = folder.path + "/./"
        guard case .resolved(let specs) = SourceRequest.resolve([.folder(awkward)]) else {
            Issue.record("expected it to resolve")
            return
        }
        #expect(specs[0].locator == folder.standardizedFileURL.path(percentEncoded: false))
    }

    /// Whether a path is already a source is a question about the list it is
    /// joining, and `addSources` answers it. This only answers whether the path
    /// is real.
    @Test("Duplicates are left for the list to deal with")
    func duplicatesSurvive() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        guard case .resolved(let specs) = SourceRequest.resolve([
            .folder(folder.path), .folder(folder.path),
        ]) else {
            Issue.record("expected it to resolve")
            return
        }
        #expect(specs.count == 2)
    }

    @Test("A path of the wrong kind refuses the batch, distinctly from a missing one")
    func wrongKindIsItsOwnRefusal() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "photo.png")
        FileManager.default.createFile(
            atPath: file.path(percentEncoded: false), contents: Data([0xAB]))

        // A file asked for as a folder, and a folder asked for as a file. Both
        // exist, so "missing" would be a lie; both are the wrong shape, so
        // accepting either stores a source that can never produce.
        #expect(
            SourceRequest.resolve([.folder(file.path(percentEncoded: false))])
                == .mismatched([file.standardizedFileURL.path(percentEncoded: false)]))
        guard case .mismatched(let paths) = SourceRequest.resolve([
            .file(folder.path(percentEncoded: false))
        ]) else {
            Issue.record("expected a mismatch")
            return
        }
        #expect(paths.count == 1)

        // Missing outranks mismatched: the batch with both is refused as
        // missing, naming the likelier typo.
        #expect(
            SourceRequest.resolve([
                .folder(file.path(percentEncoded: false)), .folder("/nowhere/at/all"),
            ]) == .missing(["/nowhere/at/all"]))
    }

    @Test("An empty batch resolves to nothing rather than failing")
    func emptyBatch() {
        #expect(SourceRequest.resolve([]) == .resolved([]))
    }

    @Test("Each source in a batch keeps its own answer about recursion")
    func recursionIsPerFolder() throws {
        let flat = try makeFolder()
        let nested = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: flat)
            try? FileManager.default.removeItem(at: nested)
        }

        guard case .resolved(let specs) = SourceRequest.resolve([
            .folder(nested.path, recursive: true), .folder(flat.path),
        ]) else {
            Issue.record("expected it to resolve")
            return
        }
        #expect(specs[0].recursive)
        #expect(!specs[1].recursive)
    }
}
