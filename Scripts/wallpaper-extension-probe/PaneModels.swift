// The probe's section in System Settings › Wallpaper. `Wallpaper Plan.md`,
// *The second probe*.
//
// `WallpaperAgent` takes the section as the private class
// `WallpaperSettingsViewModelsXPC`, which decodes Swift `Codable` values of
// `WallpaperTypes` from a keyed archive. Those types are not ours to import, so
// the values are written out here in the same shape — the property names and
// case names are Apple's, read from Phosphene's mirrors of them — archived under
// a class name of our own, and unarchived as the real class.

import Foundation

/// A coding key spelled at run time: the case names below are Apple's.
struct NamedKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}

/// A payload-free enum case the way Swift's synthesized `Codable` writes one:
/// the case name as a key over an empty container.
struct EnumCase: Encodable {
    let name: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: NamedKey.self)
        _ = container.nestedContainer(keyedBy: NamedKey.self, forKey: NamedKey(name))
    }
}

/// The identifier types that are a struct around one `id` string.
struct WrappedID: Encodable {
    let id: String
}

/// `ChoiceProviderID`, which encodes as its bare string.
struct ProviderID: Encodable {
    let rawValue: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ChoiceIdentity: Encodable {
    struct Descriptor: Encodable {
        let provider: ProviderID
        let identifier: String
        let files: [URL]
        let configuration: Data
    }

    let id: String
    let descriptor: Descriptor
}

/// `WallpaperThumbnail.image(url:)`.
struct ImageThumbnail: Encodable {
    let url: URL

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: NamedKey.self)
        var image = container.nestedContainer(keyedBy: NamedKey.self, forKey: NamedKey("image"))
        try image.encode(url, forKey: NamedKey("url"))
    }
}

struct ChoiceDescription: Encodable {
    let id: ChoiceIdentity
    let provider: ProviderID
    let identifier: String
    let name: String
    let localizedDescription: String
    let thumbnail: ImageThumbnail
    let isDownloaded: Bool
    let options: [EnumCase]
}

struct SettingsItem: Encodable {
    let id: ChoiceIdentity
    let localizedName: String
    let thumbnail: ImageThumbnail
    let choice: ChoiceDescription
    let contentBadge: EnumCase
    let showInTopLevel: Bool
    let sortOrder: Int
    let disposability: EnumCase
}

struct SettingsGroup: Encodable {
    let id: WrappedID
    let items: [SettingsItem]
    let localizedName: String
    let disposability: EnumCase
    let sortOrder: Int
    let sortID: WrappedID?
    let shouldHideItemLabels: Bool
}

struct SettingsViewModel: Encodable {
    let groups: [SettingsGroup]
    let refreshPolicy: EnumCase
    let isModificationDisabled: Bool
}

struct SettingsViewModels: Encodable {
    let desktop: SettingsViewModel?
    let screenSaver: SettingsViewModel?
}

/// The archive's root object, under a class name of our own that the
/// unarchiver maps to `WallpaperSettingsViewModelsXPC`. The key is the one the
/// real class reads.
@objc(PGRProbeSettingsViewModels)
final class ArchivedSettingsViewModels: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let value: SettingsViewModels

    init(_ value: SettingsViewModels) {
        self.value = value
        super.init()
    }

    init?(coder _: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else {
            probe("view models: coder is not a keyed archiver")
            return
        }
        do {
            try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
        } catch {
            probe("view models: encoding failed: \(error)")
        }
    }
}

enum PaneModels {
    static let itemID = "probe-picture"

    static func make(thumbnail: URL) -> SettingsViewModels {
        let provider = ProviderID(rawValue: Bundle.main.bundleIdentifier ?? "com.sydpolk.photogoround.wallpaper-probe.extension")
        let identity = ChoiceIdentity(
            id: itemID,
            descriptor: .init(provider: provider, identifier: itemID, files: [], configuration: Data(itemID.utf8)))
        let item = SettingsItem(
            id: identity,
            localizedName: "Probe Picture",
            thumbnail: ImageThumbnail(url: thumbnail),
            choice: ChoiceDescription(
                id: identity,
                provider: provider,
                identifier: itemID,
                name: "Probe Picture",
                localizedDescription: "Photo-Go-Round wallpaper probe",
                thumbnail: ImageThumbnail(url: thumbnail),
                isDownloaded: true,
                options: []),
            contentBadge: EnumCase(name: "none"),
            showInTopLevel: true,
            sortOrder: 0,
            disposability: EnumCase(name: "none"))
        // Sort order and sort id are Phosphene's, which are known to put a
        // section in the pane; what they mean has not been looked into.
        let group = SettingsGroup(
            id: WrappedID(id: "photo-go-round"),
            items: [item],
            localizedName: "Photo-Go-Round",
            disposability: EnumCase(name: "none"),
            sortOrder: -100,
            sortID: WrappedID(id: "com.apple.wallpaper.aerials"),
            shouldHideItemLabels: false)
        let model = SettingsViewModel(
            groups: [group], refreshPolicy: EnumCase(name: "default"), isModificationDisabled: false)
        // Both pickers, as Phosphene answers: the screen saver is the wallpaper
        // shown while idle, so the section may appear there too.
        return SettingsViewModels(desktop: model, screenSaver: model)
    }

    /// The view models as `WallpaperSettingsViewModelsXPC`, or nil with the
    /// reason logged.
    static func archived(thumbnail: URL) -> AnyObject? {
        let data: Data
        do {
            data = try NSKeyedArchiver.archivedData(
                withRootObject: ArchivedSettingsViewModels(make(thumbnail: thumbnail)), requiringSecureCoding: false)
        } catch {
            probe("view models: archiving failed: \(error)")
            return nil
        }
        guard let realClass = NSClassFromString("WallpaperSettingsViewModelsXPC") else {
            probe("view models: WallpaperSettingsViewModelsXPC is not loaded")
            return nil
        }
        let unarchiver: NSKeyedUnarchiver
        do {
            unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        } catch {
            probe("view models: unarchiver failed: \(error)")
            return nil
        }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(realClass, forClassName: "PGRProbeSettingsViewModels")
        let decoded = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        if let error = unarchiver.error {
            probe("view models: decoding as WallpaperSettingsViewModelsXPC failed: \(error)")
        }
        unarchiver.finishDecoding()
        guard let decoded else {
            probe("view models: decoded nothing")
            return nil
        }
        probe("view models: \(data.count) bytes decoded as \(NSStringFromClass(type(of: decoded as AnyObject)))")
        return decoded as AnyObject
    }
}
