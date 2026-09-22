import Foundation
import Testing

@testable import photogoroundd

/// The examples in `--help` have to survive the parser.
///
/// They are prose in a string literal, so nothing connects them to the grammar
/// they demonstrate and nothing fails when the grammar moves underneath them.
/// That is not hypothetical: making `--recursive` a modifier on the folder it
/// precedes left both binaries' `EXAMPLES` showing a form the new parser
/// rejects — usage text that would not run.
@Suite("Usage examples")
struct UsageExamplesTests {

    /// Every invocation of `binary` in the `EXAMPLES` section, as its arguments
    /// and the environment assignments written in front of it.
    ///
    /// Continuations are joined first, so a command wrapped across lines is one
    /// command. Anything that is not an invocation — an `export`, a blank line —
    /// is skipped rather than guessed at.
    static func examples(
        in usage: String, binary: String
    ) -> [(arguments: [String], environment: [String: String])] {
        guard let marker = usage.range(of: "EXAMPLES") else { return [] }
        let body = usage[marker.upperBound...].replacingOccurrences(of: "\\\n", with: " ")

        return body.split(separator: "\n").compactMap { line in
            var tokens = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            var environment: [String: String] = [:]

            while let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
                let halves = first.split(separator: "=", maxSplits: 1).map(String.init)
                environment[halves[0]] = halves.count > 1 ? halves[1] : ""
                tokens.removeFirst()
            }
            guard tokens.first == binary else { return nil }
            tokens.removeFirst()
            return (tokens, environment)
        }
    }

    @Test("The usage text actually contains examples to check")
    func examplesAreFound() {
        let found = Self.examples(in: Options.usage, binary: "photogoroundd")
        #expect(found.count >= 2, "found \(found.count); the extractor may have stopped matching")
    }

    @Test("Every example in `--help` parses")
    func everyExampleParses() throws {
        for example in Self.examples(in: Options.usage, binary: "photogoroundd") {
            let rendered = example.arguments.joined(separator: " ")
            #expect(throws: Never.self, "photogoroundd \(rendered)") {
                try Options.parse(example.arguments, environment: example.environment)
            }
        }
    }

    @Test("An example that stopped parsing would be caught")
    func theCheckHasTeeth() {
        // The exact shape that broke: `-r` trailing the path it used to apply to.
        let stale = "EXAMPLES\n  photogoroundd --add-folder ~/Pictures/Wallpaper -r\n"
        let found = Self.examples(in: stale, binary: "photogoroundd")
        #expect(found.count == 1)
        #expect(throws: (any Error).self) {
            try Options.parse(found[0].arguments, environment: [:])
        }
    }
}
