import Foundation
import PhotosGoRoundDisplay
import Testing

@testable import Photo_Go_Round

/// What the About box offers for each reading of the agent's port.
///
/// The path is pinned on the agent's side by `DashboardEndpointTests`; this
/// pins the app's spelling of it, so a rename on either side fails a test.
@Suite("Dashboard link")
@MainActor
struct DashboardLinkTests {

    @Test("A published port links to that port's dashboard")
    func published() {
        #expect(
            DashboardLink(.published(52811, from: .suite))
                == .open(URL(string: "http://localhost:52811/dashboard")!))
    }

    /// The sandboxed route to the same port. The About box is not sandboxed,
    /// but `ServicePort.read` falls through to the file on an empty suite, and
    /// the link must not care which answered.
    @Test("A port read from the preference file links the same way")
    func publishedFromTheFile() {
        #expect(
            DashboardLink(.published(52811, from: .file))
                == .open(URL(string: "http://localhost:52811/dashboard")!))
    }

    @Test("No published port says the agent is not running")
    func notRunning() {
        #expect(DashboardLink(ServicePort.Reading.none) == .notRunning)
    }

    @Test("A domain that cannot be read says so, and why")
    func unreadable() {
        #expect(
            DashboardLink(.unreadable(reason: "the preference file would not parse"))
                == .unreadable(reason: "the preference file would not parse"))
    }
}
