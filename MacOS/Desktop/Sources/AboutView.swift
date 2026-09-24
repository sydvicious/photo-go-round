import PhotosGoRoundAgentAPI
import PhotosGoRoundDisplay
import SwiftUI

/// The About box.
///
/// Every string in it comes from the bundle rather than from here, so the app's
/// name, its version, and its copyright are stated once — in the xcconfig — and
/// this only decides how they are arranged.
///
/// **It also links to the agent's dashboard**, and the link's text is the URL,
/// so it is where to find the port the agent is listening on.
struct AboutView: View {
    static let windowID = "about"

    /// The library every other window in the app talks to: this build's.
    var preferences = MacHostEnvironment().preferences

    var body: some View {
        VStack(spacing: 10) {
            Text(Bundle.main.displayName)
                .font(.largeTitle)

            if let copyright = Bundle.main.copyright {
                Text(copyright)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(Bundle.main.versionAndBuild)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // **Re-read on a timer, not once.** The agent takes a new port every
            // launch, and this window can stay open across a restart — a link
            // read when it opened would point at nothing.
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                DashboardLinkLine(
                    link: DashboardLink(ServicePort.read(preferences)),
                    service: SourceService(preferences: preferences))
            }
            .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(minWidth: 320)
    }
}

/// What the About box offers for the agent's dashboard.
///
/// A value rather than a branch in the view, so what each reading of the port
/// turns into can be asserted without drawing anything.
enum DashboardLink: Equatable {
    case open(URL)
    /// No port is published: the agent is not running, or stopped and withdrew it.
    case notRunning
    /// The preference domain exists and could not be read.
    case unreadable(reason: String)

    /// Served by the agent's `DashboardEndpoint.pagePath`.
    static let path = "/dashboard"

    /// The page's address with a one-time code the agent will trade for its
    /// cookie. What the browser is handed; the text on the button stays the
    /// plain address, which is where to find the port.
    static func url(_ page: URL, code: String) -> URL {
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url!
    }

    init(_ reading: ServicePort.Reading) {
        switch reading {
        case .published(let port, _):
            self = .open(URL(string: "http://localhost:\(port)\(Self.path)")!)
        case .none:
            self = .notRunning
        case .unreadable(let reason):
            self = .unreadable(reason: reason)
        }
    }
}

private struct DashboardLinkLine: View {
    let link: DashboardLink
    let service: SourceService

    @Environment(\.openURL) private var openURL
    /// Why the last click did not open the page, until the next one.
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 2) {
            Text("Agent Dashboard")
                .font(.callout)
                .foregroundStyle(.secondary)

            switch link {
            case .open(let url):
                // **A button now, not a `Link`.** The browser cannot send the
                // secret, so a click first asks the agent for a one-time code
                // and hands the browser the page with that; the agent trades it
                // for a cookie. `openURL` gives the address to the system, so
                // the dashboard opens in the default browser — never in a web
                // view of the app's own. `Plans/Multi-user Support.md`.
                Button(url.absoluteString) { open(url) }
                    .buttonStyle(.link)
                    .font(.callout)
                    .monospacedDigit()
                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .notRunning:
                // The words the picture window uses for the same condition.
                Text("Waiting for Photos")
                    .font(.callout)
            case .unreadable(let reason):
                Text("The agent's port could not be read: \(reason)")
                    .font(.callout)
            }
        }
    }

    private func open(_ page: URL) {
        Task {
            do {
                let code = try await service.dashboardCode()
                failure = nil
                openURL(DashboardLink.url(page, code: code))
            } catch {
                failure = SourcesModel.explain(error)
            }
        }
    }
}

extension Bundle {
    /// What the app calls itself. `CFBundleDisplayName` is what the user sees
    /// and what the Finder shows; `CFBundleName` is the fallback for a bundle
    /// that never set one.
    var displayName: String {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Photos-Go-Round"
    }

    /// `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, which reach the bundle
    /// as these two keys.
    var versionAndBuild: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    var copyright: String? {
        object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }
}

#Preview {
    AboutView()
}
