import Foundation
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundDisplay

/// The wallpaper extension is sandboxed, so every preference domain it reads
/// has to be named in its entitlements. The domains carry the build variant and
/// the entitlements did not, and nothing noticed.
///
/// **What it cost, measured 2026-09-19.** Syd's Debug extension asked for
/// `com.sydpolk.photosgoround.debug.dev`; the entitlements granted
/// `com.sydpolk.photosgoround.dev`; the sandbox refused the read, and the log
/// said, every ten seconds, *the port in com.sydpolk.photosgoround.debug.dev
/// could not be read … no agent answered; the desktop keeps what it has*. The
/// desktop stopped changing on the day the three configurations landed. The
/// suffix is `$(STORAGE_ID_SUFFIX)` in the entitlements now, expanded by Xcode
/// at signing — verified against the signed `.appex`, which named
/// `com.sydpolk.photosgoround.claude.dev` in a `Claude` build.
///
/// **This suite keeps the two halves honest**, as `BuildVariantTests` does for
/// the product names: it reads the entitlements file, substitutes each
/// variant's suffix, and compares the result against the domains the
/// extension's own code computes. `BuildVariantTests` separately holds
/// `STORAGE_ID_SUFFIX` in `project.pbxproj` equal to
/// `BuildVariant.identifierSuffix`, which is the substitution Xcode performs.
///
/// `Plans/Wallpaper Plan.md`.
@Suite("The wallpaper's entitlements name the domains it reads")
struct WallpaperEntitlementsTests {

    /// The build setting the entitlements spell the variant with.
    static let placeholder = "$(STORAGE_ID_SUFFIX)"

    /// The two exception lists, and whether the sandbox key is there at all —
    /// read once, and `Sendable`, which the raw plist dictionary is not.
    struct Entitlements: Sendable {
        var sandboxed = false
        var domains: [String] = []
        var files: [String] = []
    }

    static let entitlements: Entitlements = {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()  // PhotosGoRoundDisplayTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Shared
            .deletingLastPathComponent()  // the package root
            .appending(path: "MacOS/Wallpaper/Resources/Photos-Go-Round Wallpaper.entitlements")
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else { return Entitlements() }
        let prefix = "com.apple.security.temporary-exception."
        return Entitlements(
            sandboxed: dictionary["com.apple.security.app-sandbox"] as? Bool == true,
            domains: dictionary["\(prefix)shared-preference.read-only"] as? [String] ?? [],
            files: dictionary["\(prefix)files.home-relative-path.read-only"] as? [String] ?? [])
    }()

    /// An exception list with one variant's suffix put in, which is what the
    /// signed bundle carries.
    static func granted(_ list: [String], _ variant: BuildVariant) -> Set<String> {
        Set(list.map { $0.replacingOccurrences(of: placeholder, with: variant.identifierSuffix) })
    }

    /// Every domain the entitlements grant, for one variant: the agent's and
    /// the wallpaper's own. One of each per build since 2026-09-24, when the
    /// `.dev` and `.prod` pair inside every build went.
    static func domainsRead(by variant: BuildVariant) -> Set<String> {
        [
            MacHostEnvironment.preferenceDomain(variant: variant),
            WallpaperPreferences(variant: variant).domain,
        ]
    }

    @Test("The entitlements file was found and parsed")
    func entitlementsAreReadable() {
        #expect(Self.entitlements.sandboxed, "the sandbox key is gone, or the file would not parse")
    }

    @Test("Every domain the extension reads is granted", arguments: BuildVariant.allCases)
    func everyDomainIsGranted(_ variant: BuildVariant) {
        let granted = Self.granted(Self.entitlements.domains, variant)
        let read = Self.domainsRead(by: variant)
        #expect(
            granted == read,
            "\(variant.rawValue): read but not granted \(read.subtracting(granted).sorted()); granted but not read \(granted.subtracting(read).sorted())"
        )
    }

    /// The suite can open and hold nothing inside a sandbox, so both surfaces
    /// fall back to the domain's file — which needs its own exception.
    @Test("Every granted domain's plist is granted too", arguments: BuildVariant.allCases)
    func everyPlistIsGranted(_ variant: BuildVariant) {
        let files = Self.granted(Self.entitlements.files, variant)
        let wanted = Set(Self.domainsRead(by: variant).map { "/Library/Preferences/\($0).plist" })
        #expect(
            files == wanted,
            "\(variant.rawValue): missing \(wanted.subtracting(files).sorted()); spare \(files.subtracting(wanted).sorted())"
        )
    }

    /// The whole point of the placeholder: a list written without it grants the
    /// Release domains to all three builds, which is the bug this suite exists
    /// for.
    @Test("The domains are spelled with the suffix rather than fixed")
    func everyEntryCarriesThePlaceholder() {
        let entries = Self.entitlements.domains + Self.entitlements.files
        #expect(!entries.isEmpty, "both exception lists are empty")
        for entry in entries {
            #expect(entry.contains(Self.placeholder), "\(entry) names no build variant")
        }
    }
}
