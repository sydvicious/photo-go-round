import Foundation
import Testing

@testable import Photo_Go_Round

/// What a collection's row says about where it stands.
///
/// **The state a person most needs is the one this window could not show.**
/// Until 2026-09-07 the chosen collections were a comma-joined list of names,
/// so an album the agent could not reach looked exactly like one that was fine
/// — and on a machine whose photo library had stopped answering, every album
/// looked fine while none of them were.
///
/// The rule these hold to is the one the folder rows and the missing-albums
/// line already follow: **the words carry the meaning and the colour only
/// underlines it.** Nothing here is legible only as a colour.
@Suite("What a collection's row says")
@MainActor
struct SourceStandingWordsTests {

    private func collection(
        available: Bool = true, reason: String? = nil, missing: Bool? = nil,
        photos: Int = 40, scanned: Bool = true
    ) -> SourceService.Source {
        SourceService.Source(
            uuid: "S1", kind: "photos_collection", locator: "LIB/L0/040",
            recursive: nil, enabled: true, available: available,
            unavailableReason: reason, title: "Sunsets", missing: missing,
            reconnectable: nil, photos: photos,
            scannedAt: scanned ? Date(timeIntervalSince1970: 0) : nil)
    }

    @Test("A counted collection says how many photographs it holds")
    func aCountedCollectionSaysSo() {
        let standing = SourcesSettingsView.standing(of: collection(photos: 1284))
        #expect(standing.words == "1,284 photos")
        #expect(!standing.isTrouble)
    }

    /// Saying "0 photos" about an album nobody has walked yet would be a claim
    /// rather than a delay — the same reason a freshly added folder says this.
    @Test("A collection nobody has walked yet says so rather than claiming zero")
    func anUnscannedCollectionDoesNotClaimZero() {
        let standing = SourcesSettingsView.standing(of: collection(photos: 0, scanned: false))
        #expect(standing.words == "scanning…")
        #expect(!standing.isTrouble)
    }

    /// **The case this was built for.** The agent's own sentence, verbatim,
    /// because it names what went wrong and which call it was.
    @Test("An unreachable collection shows the agent's own reason")
    func anUnreachableCollectionGivesTheReason() {
        let reason = "the photo library did not answer enumerateImages within 10.0 seconds"
        let standing = SourcesSettingsView.standing(
            of: collection(available: false, reason: reason))
        #expect(standing.words == reason)
        #expect(standing.isTrouble)
    }

    /// Unavailable with nothing said about why still has to say *something* —
    /// a blank column reads as fine.
    @Test("An unreachable collection with no reason still says it is unreachable")
    func anUnreachableCollectionAlwaysSaysSomething() {
        let standing = SourcesSettingsView.standing(of: collection(available: false))
        #expect(standing.words == "unavailable")
        #expect(standing.isTrouble)
    }

    /// Missing outranks the generic unavailable, because it is the one a person
    /// can act on — Reconnect and Remove are offered for exactly this.
    @Test("A missing album is named as missing rather than merely unavailable")
    func missingOutranksUnavailable() {
        let standing = SourcesSettingsView.standing(
            of: collection(available: false, reason: "offline", missing: true))
        #expect(standing.words == "not in this library")
        #expect(standing.isTrouble)
    }

    /// Every state says words. A row whose meaning lived in its tint would be
    /// unreadable to anyone who cannot separate the two colours.
    @Test("Every state has words of its own, so none of them is only a colour")
    func nothingIsCarriedByColourAlone() {
        let states = [
            collection(),
            collection(scanned: false),
            collection(available: false, reason: "offline"),
            collection(available: false, missing: true),
        ]
        for source in states {
            #expect(!SourcesSettingsView.standing(of: source).words.isEmpty)
        }
    }
}
