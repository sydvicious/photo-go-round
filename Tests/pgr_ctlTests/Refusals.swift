import Console
import Foundation
import Synchronization

/// What commands that refuse by design said, collected rather than printed.
///
/// **Several commands here refuse on purpose, and the refusal is the behaviour
/// under test.** Left alone they write `error:` to standard error, so a run in
/// which nothing went wrong prints three of them — which teaches whoever reads
/// that output to skim past the word, and that is the only word worth not
/// skimming past.
///
/// Process-global because `Console` is, and installed on first use rather than
/// in a setup hook, since Swift Testing has none. Assert with `contains`: these
/// suites run in parallel, so another test's refusal can land here too.
enum Refusals {
    private static let said = Mutex<[String]>([])

    /// Touch this before running anything that refuses.
    static let installed: Void = {
        Console.redirectFailures { text in said.withLock { $0.append(text) } }
    }()

    static var all: [String] { said.withLock { $0 } }
}
