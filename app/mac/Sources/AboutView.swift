import SwiftUI

/// The About box.
///
/// Every string in it comes from the bundle rather than from here, so the app's
/// name, its version, and its copyright are stated once — in the xcconfig — and
/// this only decides how they are arranged.
struct AboutView: View {
    static let windowID = "about"

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
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(minWidth: 320)
    }
}

extension Bundle {
    /// What the app calls itself. `CFBundleDisplayName` is what the user sees
    /// and what the Finder shows; `CFBundleName` is the fallback for a bundle
    /// that never set one.
    var displayName: String {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Photo-Go-Round"
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
