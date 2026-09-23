import Foundation

/// `pluginkit`, which has no API.
enum PluginKit {

    static func registrations(for extensionPoint: String) -> [WallpaperInstall.Registration] {
        let listed = Shell.run("/usr/bin/pluginkit", ["-m", "-D", "-v", "-p", extensionPoint])
        return WallpaperInstall.parseRegistrations(listed.output)
    }

    /// Registers the appex. **It must be inside a signed app bundle**: measured
    /// 2026-09-15, `pluginkit -a` on a bare `.appex`, or on a bundle holding
    /// only an `Info.plist`, exits 0 and registers nothing.
    static func add(_ appex: URL) {
        Shell.run("/usr/bin/pluginkit", ["-a", appex.path(percentEncoded: false)])
    }

    static func remove(_ path: String) {
        Shell.run("/usr/bin/pluginkit", ["-r", path])
    }

    /// What the bundle at this path says its identifier is, or nil when there is
    /// no readable bundle there at all — which is how a dead registration is
    /// told from a live one.
    static func identifier(ofBundleAt path: String) -> String? {
        let info = URL(filePath: path).appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
            let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let identifier = values["CFBundleIdentifier"] as? String, !identifier.isEmpty
        else { return nil }
        return identifier
    }
}
