import Foundation

/// The dashboard's page, stylesheet and script, as files. See `DashboardEndpoint`.
///
/// **In `MacOS/Agent/Dashboard/Resources/`, not in a Swift string.** They were one raw
/// string in this file until 2026-09-16. Syd: "these files should go in the same
/// directory the agent sources are in, with a subdirectory /js". As files they
/// get a real editor and `node --check`. They moved out of the agent's source
/// folder in the 2026-09-22 reorganization, so SwiftPM never sees them.
///
/// **Where they are found, in order:**
///
/// 1. **The agent's app bundle**, `Contents/Resources`. The Xcode target
///    `Photo-Go-Round Server` syncs `MacOS/Agent/Dashboard/Resources` and copies
///    these there, so an installed agent — from DerivedData or shipped — reads
///    its own copy.
/// 2. **The dashboard's `Resources` folder in the checkout**, for a build with no app bundle:
///    `swift test`, and an agent run from `swift build`. The path is the one
///    this file was compiled at, so it only resolves on the machine that built it.
///
/// Read on every request rather than once, so an edit shows on the next reload
/// of a development agent; they are a few kilobytes off the boot volume.
enum DashboardPage {

    enum Asset: String, CaseIterable, Sendable {
        case html = "dashboard.html"
        case css = "dashboard.css"
        case js = "dashboard.js"

        var contentType: String {
            switch self {
            case .html: "text/html; charset=utf-8"
            case .css: "text/css; charset=utf-8"
            case .js: "text/javascript; charset=utf-8"
            }
        }
    }

    /// The asset's bytes, or nil when neither place has it.
    static func contents(
        of asset: Asset, bundle: Bundle = .main, source: String = #filePath
    ) -> Data? {
        for url in candidates(for: asset, bundle: bundle, source: source) {
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    /// Where `contents(of:)` looks, in the order it looks.
    static func candidates(
        for asset: Asset, bundle: Bundle = .main, source: String = #filePath
    ) -> [URL] {
        var urls: [URL] = []
        if let resources = bundle.resourceURL {
            urls.append(resources.appending(path: asset.rawValue))
        }
        urls.append(sourceDirectory(source: source).appending(path: asset.rawValue))
        return urls
    }

    /// `MacOS/Agent/Dashboard/Resources/`, reached from
    /// `MacOS/Agent/Dashboard/Sources/DashboardPage.swift`.
    static func sourceDirectory(source: String = #filePath) -> URL {
        URL(filePath: source)
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // Dashboard
            .appending(path: "Resources", directoryHint: .isDirectory)
    }
}
