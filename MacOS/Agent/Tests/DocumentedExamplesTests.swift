import Foundation
import Synchronization
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundServer

/// The `curl` examples in the documentation, read and run.
///
/// **Documented means tested.** Every example has to carry the secret, or the
/// agent refuses it — so every `curl` in `README.md` and `Documentation/` is
/// checked for the header, and the README's and `pgr_ctl.md`'s examples are run
/// through `zsh` exactly as written, against a gated listener. Syd,
/// 2026-09-23, asked whether to read them, run them, or both: both.
/// `Plans/Multi-user Support.md`, *Documentation*.
///
/// What is proven is that each example gets through the gate as written, not
/// what the agent then answers — the route behind the gate answers everything.
/// The endpoints have suites of their own.
@Suite("Documented examples", .timeLimit(.minutes(1)))
struct DocumentedExamplesTests {

    /// The header every example sends, as the documents spell it.
    static let header = #"-H "$AUTH""#

    static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func document(_ path: String) throws -> String {
        try String(contentsOf: repository.appending(path: path), encoding: .utf8)
    }

    /// `README.md` and every Markdown file in `Documentation/`.
    static func documents() throws -> [String] {
        let folder = repository.appending(path: "Documentation")
        let pages = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasSuffix(".md") }
            .sorted()
            .map { "Documentation/\($0)" }
        return ["README.md"] + pages
    }

    /// The contents of each fenced block, in order.
    static func fencedBlocks(in markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring]?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let finished = current {
                    blocks.append(finished.joined(separator: "\n"))
                    current = nil
                } else {
                    current = []
                }
            } else {
                current?.append(line)
            }
        }
        return blocks
    }

    /// Every line that runs `curl`: at its start, or after `do`, `;`, `&&` or `|`.
    /// Prose that names `curl` in backticks is not an invocation.
    static func invocations(in text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            line.contains(/(^\s*|\bdo\s+|[;&|]\s*)curl\s+-/)
        }
    }

    // MARK: - Read

    @Test("Every curl in the documentation carries the secret")
    func everyCurlCarriesTheSecret() throws {
        var found = 0
        for path in try Self.documents() {
            for line in Self.invocations(in: try Self.document(path)) {
                found += 1
                #expect(line.contains(Self.header), "\(path): \(line)")
            }
        }
        // The README, `pgr_ctl.md` and the agent's man page all have some.
        #expect(found >= 10, "found \(found); the extractor may have stopped matching")
    }

    @Test("The README sets DOMAIN, PORT and AUTH before its examples")
    func theSetupBlockIsThere() throws {
        let setup = try #require(try Self.setupBlock())
        #expect(setup.contains(#"PORT=$(defaults read "$DOMAIN" servicePort)"#))
        #expect(setup.contains(#"AUTH="Authorization: Bearer $(defaults read "$DOMAIN" serviceSecret)""#))
    }

    static func setupBlock() throws -> String? {
        fencedBlocks(in: try document("README.md")).first { $0.contains("AUTH=") && !$0.contains("curl") }
    }

    // MARK: - Run

    /// Every fenced block with a `curl` in it, from the documents that are run.
    static func runnableExamples() throws -> [(path: String, block: String)] {
        try ["README.md", "Documentation/pgr_ctl.md"].flatMap { path in
            fencedBlocks(in: try document(path))
                .filter { !invocations(in: $0).isEmpty }
                .map { (path, $0) }
        }
    }

    @Test("Each example gets through the gate as written, and is refused without the header")
    func examplesGetThroughTheGate() async throws {
        let examples = try Self.runnableExamples()
        #expect(examples.count >= 7, "found \(examples.count) blocks to run")
        let setup = try #require(try Self.setupBlock())

        let rig = try await Rig.start()
        defer { rig.stop() }

        for example in examples {
            let label = "\(example.path): \(example.block.prefix(60))"

            let written = rig.script(setup: setup, example: example.block)
            let admitted = try await rig.run(written)
            #expect(admitted.status == 0, "\(label) exited \(admitted.status): \(admitted.output)")
            #expect(admitted.passed > 0, "\(label) reached nothing")
            #expect(admitted.refused == 0, "\(label) was refused \(admitted.refused) times")

            let bare = rig.script(
                setup: setup, example: example.block.replacingOccurrences(of: Self.header + " ", with: ""))
            let refused = try await rig.run(bare)
            #expect(refused.passed == 0, "\(label) got through without the header")
            #expect(refused.refused > 0, "\(label) without the header was not refused")
        }
    }

    // MARK: - The rig

    /// A gated listener on a kernel port, and a preference file holding its port
    /// and a secret, where `defaults read` will find them.
    final class Rig: Sendable {
        let listener: HTTPListener
        let directory: URL
        let counts = Mutex((passed: 0, refused: 0))

        private init(listener: HTTPListener, directory: URL) {
            self.listener = listener
            self.directory = directory
        }

        static func start() async throws -> Rig {
            let directory = URL.temporaryDirectory.appending(path: "pgr-docs-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let secret = try #require(ServiceSecret.make())
            let bound = RequestBodyTests.BoundPort()
            let box = Mutex<Rig?>(nil)
            let gate = ServiceGate(secret: secret, refused: { _ in
                box.withLock { $0 }?.counts.withLock { $0.refused += 1 }
            })
            let listener = HTTPListener(port: nil, advertising: "", onReady: { bound.set($0) }) { request in
                await gate.handle(request) { _ in
                    box.withLock { $0 }?.counts.withLock { $0.passed += 1 }
                    // A content type the README's save-with-the-right-extension
                    // example can read.
                    return HTTPListener.Response(
                        status: 200, reason: "OK", headers: ["Content-Type": "image/jpeg"],
                        body: .data(Data("[]".utf8)))
                }
            }
            let rig = Rig(listener: listener, directory: directory)
            box.withLock { $0 = rig }
            try listener.start()
            let port = await bound.value

            // Written as a file, so `defaults read` in the child finds it on
            // disk rather than depending on this process's writes reaching it.
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["servicePort": Int(port), "serviceSecret": secret],
                format: .binary, options: 0)
            try plist.write(to: rig.domainPath.appendingPathExtension("plist"))
            return rig
        }

        /// A path domain — `defaults read /path/name` reads `/path/name.plist`.
        var domainPath: URL { directory.appending(path: "domain") }

        func stop() {
            listener.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        /// The setup and the example, with the domain pointed here, `/tmp/`
        /// pointed at this rig's directory, and nothing opened in Preview.
        func script(setup: String, example: String) -> String {
            let domain = "DOMAIN=\"\(domainPath.path(percentEncoded: false))\""
            let text = (setup + "\n" + example)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasPrefix("DOMAIN=") ? domain : String($0) }
                .map { line -> String in
                    guard let open = line.range(of: " && open ") else { return line }
                    return String(line[..<open.lowerBound])
                }
                .joined(separator: "\n")
            return "set -e\n" + text.replacingOccurrences(
                of: "/tmp/", with: directory.path(percentEncoded: false) + "/")
        }

        struct Outcome {
            var status: Int32
            var output: String
            var passed: Int
            var refused: Int
        }

        /// Runs `script` in `zsh` and reports what reached the gate meanwhile.
        func run(_ script: String) async throws -> Outcome {
            counts.withLock { $0 = (0, 0) }
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-c", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output

            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            let text = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let (passed, refused) = counts.withLock { $0 }
            return Outcome(status: status, output: text, passed: passed, refused: refused)
        }
    }
}
