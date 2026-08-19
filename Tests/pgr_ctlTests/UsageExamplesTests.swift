import Foundation
import Testing

@testable import pgr_ctl

/// The examples in `--help` have to survive the parser. See the agent's suite of
/// the same name for why this is not hypothetical.
@Suite("pgr_ctl usage examples")
struct UsageExamplesTests {

    static func examples(in usage: String, binary: String) -> [[String]] {
        guard let marker = usage.range(of: "EXAMPLES") else { return [] }
        let body = usage[marker.upperBound...].replacingOccurrences(of: "\\\n", with: " ")

        return body.split(separator: "\n").compactMap { line in
            var tokens = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            while let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
                tokens.removeFirst()
            }
            guard tokens.first == binary else { return nil }
            tokens.removeFirst()
            return tokens
        }
    }

    @Test("The usage text actually contains examples to check")
    func examplesAreFound() {
        let found = Self.examples(in: Options.usage, binary: "pgr_ctl")
        #expect(found.count >= 3, "found \(found.count); the extractor may have stopped matching")
    }

    @Test("Every example in `--help` parses")
    func everyExampleParses() throws {
        for arguments in Self.examples(in: Options.usage, binary: "pgr_ctl") {
            #expect(throws: Never.self, "pgr_ctl \(arguments.joined(separator: " "))") {
                try Options.parse(arguments)
            }
        }
    }

    @Test("An example that stopped parsing would be caught")
    func theCheckHasTeeth() {
        let stale = "EXAMPLES\n  pgr_ctl sources add --folder ~/Pictures/Wallpaper -r\n"
        let found = Self.examples(in: stale, binary: "pgr_ctl")
        #expect(found.count == 1)
        #expect(throws: (any Error).self) { try Options.parse(found[0]) }
    }
}
