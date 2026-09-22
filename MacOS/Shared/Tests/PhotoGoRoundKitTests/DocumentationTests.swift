import Foundation
import Testing

/// The documentation audit, run as a test so `⌘U` and `xcodebuild test` do it.
///
/// **It shells out to `Scripts/audit-docs.sh` rather than reimplementing the
/// checks.** One implementation, driven from two doors — the same reason
/// `Scripts/uninstall.sh` is a wrapper over `pgr_install uninstall`. A Swift
/// copy of the comparisons would be a second thing to keep in step, and the
/// first time they disagreed the test would be the one believed.
///
/// `TODO.md`, *Audit all documentation against reality*: "A number repeated in
/// prose drifts silently; the fix is not only to correct it but to leave
/// something that fails when it drifts again."
///
/// **What it cannot judge is the prose**, which is where the worst finding of
/// the 2026-09-19 audit lived: a resize budget that still said one second after
/// it became 1.5. Reading is still the job.
@Suite("The documentation agrees with the code")
struct DocumentationTests {

    /// The checkout, from the path this file was compiled at. The same trick
    /// `BuildVariantTests` uses to reach `project.pbxproj`.
    static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent()  // PhotoGoRoundKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Shared
        .deletingLastPathComponent()  // MacOS
        .deletingLastPathComponent()  // the package root

    @Test("Every documented flag exists, and every flag is documented")
    func auditPasses() throws {
        let script = Self.repository.appending(path: "Scripts/audit-docs.sh")
        try #require(
            FileManager.default.isExecutableFile(atPath: script.path(percentEncoded: false)),
            "Scripts/audit-docs.sh is missing or not executable")

        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [script.path(percentEncoded: false)]
        process.currentDirectoryURL = Self.repository
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(
            process.terminationStatus == 0,
            """
            Scripts/audit-docs.sh found the documentation and the code disagreeing:

            \(output)
            """)
    }
}
