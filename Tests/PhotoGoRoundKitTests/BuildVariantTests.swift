import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI

/// `BuildVariant` states the per-configuration suffixes, and `project.pbxproj`
/// states them again as build settings — because they shape product names and
/// `Info.plist` values before any Swift runs, and Swift cannot read an
/// `.xcconfig` at runtime.
///
/// **This suite is the thing that keeps the two halves honest.** Nothing else
/// notices when they part: a saver would simply install under a name no
/// uninstall looks for, and an agent would register a label nothing boots out.
/// It reads the project file and compares.
///
/// `Plans/Xcode - Separate Build and Run.md`, *The build variant, compiled in*.
@Suite("Build identity agrees with the project file")
struct BuildVariantTests {

    /// Every setting this suite checks, as configuration → key → value.
    private static let settings: [String: [String: String]] = {
        let project = URL(filePath: #filePath)
            .deletingLastPathComponent()  // PhotoGoRoundKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: "app/Photo-Go-Round.xcodeproj/project.pbxproj")
        guard let text = try? String(contentsOf: project, encoding: .utf8) else { return [:] }

        // The project-level configurations, each a block ending in `name = X;`.
        // Only those three carry the suffixes; per-target copies were removed
        // on 2026-09-19 so that the aggregate install targets inherit them.
        var found: [String: [String: String]] = [:]
        for block in text.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst() {
            guard let body = block.range(of: "\n\t\t};").map({ String(block[block.startIndex..<$0.lowerBound]) })
            else { continue }
            guard let nameLine = body.components(separatedBy: "\n").last(where: { $0.contains("\t\t\tname = ") })
            else { continue }
            let configuration = nameLine
                .replacingOccurrences(of: "\t\t\tname = ", with: "")
                .replacingOccurrences(of: ";", with: "")
            var values: [String: String] = [:]
            for line in body.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasSuffix(";"), let equals = trimmed.range(of: " = ") else { continue }
                let key = String(trimmed[trimmed.startIndex..<equals.lowerBound])
                guard key.hasSuffix("_SUFFIX") else { continue }
                var value = String(trimmed[equals.upperBound...].dropLast())
                if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
                values[key] = value
            }
            if !values.isEmpty { found[configuration, default: [:]].merge(values) { a, _ in a } }
        }
        return found
    }()

    /// Which `BuildVariant` each Xcode configuration is.
    private static let configurations: [(String, BuildVariant)] = [
        ("Debug", .debug), ("Claude", .claude), ("Release", .release),
    ]

    @Test("The project file was found and read")
    func projectFileIsReadable() {
        #expect(Self.settings.count >= 3, "expected three configurations, read \(Self.settings.keys.sorted())")
    }

    @Test("Every configuration carries every suffix", arguments: ["Debug", "Claude", "Release"])
    func everyConfigurationIsComplete(_ configuration: String) {
        let keys = Set(Self.settings[configuration]?.keys ?? [:].keys)
        #expect(keys.isSuperset(of: [
            "SAVER_ID_SUFFIX", "SAVER_NAME_SUFFIX", "SERVER_LABEL_SUFFIX",
            "WALLPAPER_ID_SUFFIX", "WALLPAPER_NAME_SUFFIX",
        ]), "\(configuration) is missing one: \(keys.sorted())")
    }

    @Test("The identifier suffixes match", arguments: configurations)
    func identifierSuffixesMatch(_ pair: (String, BuildVariant)) {
        let (configuration, variant) = pair
        for key in ["SAVER_ID_SUFFIX", "SERVER_LABEL_SUFFIX", "WALLPAPER_ID_SUFFIX"] {
            #expect(
                Self.settings[configuration]?[key] == variant.identifierSuffix,
                "\(configuration).\(key) is \(Self.settings[configuration]?[key] ?? "absent"), BuildVariant.\(variant.rawValue) says \(variant.identifierSuffix)")
        }
    }

    @Test("The name suffixes match", arguments: configurations)
    func nameSuffixesMatch(_ pair: (String, BuildVariant)) {
        let (configuration, variant) = pair
        for key in ["SAVER_NAME_SUFFIX", "WALLPAPER_NAME_SUFFIX"] {
            #expect(
                Self.settings[configuration]?[key] == variant.nameSuffix,
                "\(configuration).\(key) is \(Self.settings[configuration]?[key] ?? "absent"), BuildVariant.\(variant.rawValue) says \(variant.nameSuffix)")
        }
    }

    @Test("No two variants share a port, a label, a saver name or an extension identifier")
    func everyVariantIsDistinct() {
        #expect(Set(BuildVariant.allCases.map(\.port)).count == BuildVariant.allCases.count)
        #expect(Set(BuildVariant.allCases.map(\.agentLabel)).count == BuildVariant.allCases.count)
        #expect(Set(BuildVariant.allCases.map(\.saverBundleName)).count == BuildVariant.allCases.count)
        #expect(
            Set(BuildVariant.allCases.map(\.wallpaperExtensionIdentifier)).count
                == BuildVariant.allCases.count)
    }

    @Test("Release carries no suffix at all, so it is the plain name everywhere")
    func releaseIsUnadorned() {
        #expect(BuildVariant.release.agentLabel == "com.sydpolk.photogoround.server")
        #expect(BuildVariant.release.saverBundleName == "Photo-Go-Round Screensaver")
        #expect(
            BuildVariant.release.wallpaperExtensionIdentifier
                == "com.sydpolk.photogoround.wallpaper.extension")
    }
}
