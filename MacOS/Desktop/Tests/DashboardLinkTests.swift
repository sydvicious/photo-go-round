import Foundation
import PhotosGoRoundDisplay
import Testing

@testable import Photos_Go_Round

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

    /// What the browser is handed: the page, with a code the agent trades for
    /// its cookie. Never the secret.
    @Test("The browser is handed the page with a one-time code")
    func handedACode() {
        let page = URL(string: "http://localhost:52811/dashboard")!
        #expect(
            DashboardLink.url(page, code: "0123abcd")
                == URL(string: "http://localhost:52811/dashboard?code=0123abcd")!)
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
