// The Photos-Go-Round section in System Settings › Wallpaper. `Wallpaper Plan.md`,
// *The second probe* for how this was measured, and *The real extension, inside
// the app*.
//
// `WallpaperAgent` takes the section as the private class
// `WallpaperSettingsViewModelsXPC`, which decodes Swift `Codable` values of
// `WallpaperTypes` from a keyed archive. Those types are not ours to import, so
// the values are written out here in the same shape — the property names and case
// names are Apple's — archived under a class name of our own, and unarchived as
// the real class.

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

/// The archive's root object, under a class name of our own that the unarchiver
/// maps to `WallpaperSettingsViewModelsXPC`. The key is the one the real class
/// reads.
@objc(PGRWallpaperSettingsViewModels)
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
            wallpaperLog("view models: coder is not a keyed archiver")
            return
        }
        do {
            try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
        } catch {
            wallpaperLog("view models: encoding failed: \(error)")
        }
    }
}

enum PaneModels {
    /// Nil when the bundle does not say who it is; see `Identity`.
    static func make(thumbnail: URL) -> SettingsViewModels? {
        // One item, which is the whole of Photos-Go-Round in the pane: the deck
        // decides what it shows, so there is nothing here to choose between.
        guard let bundleID = Identity.bundleID, let itemID = Identity.itemID,
            let itemName = Identity.itemName
        else {
            wallpaperLog("view models: \(Identity.summary)")
            return nil
        }
        // **The provider id must be the bundle identifier.** Measured 2026-09-16,
        // by trying otherwise: Apple's extensions declare choices under ids like
        // `com.apple.wallpaper.choice.image`, distinct from their bundle ids, and
        // the hypothesis was that a wallpaper-specific id would keep this item
        // out of the Screen Saver list. It did not — and it broke the desktop.
        // `WallpaperAgent` logged "Could not find translator for:
        // com.sydpolk.photosgoround.choice.wallpaper; eagerly assuming it's an
        // extension with the same identifier", then "no provider found", and the
        // desktop fell back to Golden Gate. Apple's ids work because a built-in
        // translator maps them; a third party's provider is looked up as an
        // extension by that exact identifier, so it has to be ours.
        let provider = ProviderID(rawValue: bundleID)
        let identity = ChoiceIdentity(
            id: itemID,
            descriptor: .init(provider: provider, identifier: itemID, files: [], configuration: Data(itemID.utf8)))
        let item = SettingsItem(
            id: identity,
            // **"Wallpaper", so it cannot be confused with the screensaver.**
            // Syd, 2026-09-15: one extension and one `.saver` were both called
            // "Photos-Go-Round", in two lists, and picking the wrong one gave a
            // screen saver that mirrored the desktop. The section heading below
            // stays "Photos-Go-Round"; the item says which surface it is, and
            // which build — `Identity`.
            localizedName: itemName,
            thumbnail: ImageThumbnail(url: thumbnail),
            choice: ChoiceDescription(
                id: identity,
                provider: provider,
                identifier: itemID,
                name: itemName,
                localizedDescription: "Photographs from your library, shuffled",
                thumbnail: ImageThumbnail(url: thumbnail),
                isDownloaded: true,
                options: []),
            contentBadge: EnumCase(name: "none"),
            showInTopLevel: true,
            sortOrder: 0,
            disposability: EnumCase(name: "none"))
        // Sort order and sort id are Phosphene's, which are known to put a
        // section in the pane; what they mean has not been looked into.
        //
        // **One section for every build.** Syd, 2026-09-16: "I would prefer
        // that they both go in the same section". The same identifier and
        // heading in Release, Debug and Claude's builds; only the item differs.
        let group = SettingsGroup(
            id: WrappedID(id: "photos-go-round"),
            items: [item],
            localizedName: "Photos-Go-Round",
            disposability: EnumCase(name: "none"),
            sortOrder: -100,
            sortID: WrappedID(id: "com.apple.wallpaper.aerials"),
            shouldHideItemLabels: false)
        let model = SettingsViewModel(
            groups: [group], refreshPolicy: EnumCase(name: "default"), isModificationDisabled: false)
        // **The wallpaper picker only.** Syd, 2026-09-15: "advertise to the
        // wallpaper picker only." Offering the same item in both pickers put a
        // Photos-Go-Round entry under Screen Saver as well, drawn by these same
        // surfaces — so the pane showed identical previews in two places while
        // the real `.saver` sat installed and unused, and nothing on screen said
        // which was which. The screensaver is its own product, with its own view
        // and its own loop; this is the desktop's.
        //
        // *Until then both were answered, copying Phosphene, on the reasoning
        // that the screen saver picker is where the idle wallpaper is chosen.*
        // **An empty screen-saver model, not nil.** Measured 2026-09-16: with
        // `nil` here, the Screen Saver pane kept showing a copy of the item as it
        // was *before* the rename, through restarts of WallpaperAgent, quits of
        // System Settings and rebuilds — and selecting it recorded our provider
        // with the old configuration, `photo-go-round`. So macOS keeps the last
        // non-nil screen-saver model per extension and reads `nil` as "no
        // update", not "none". A model with no groups is the way to say none.
        let none = SettingsViewModel(
            groups: [], refreshPolicy: EnumCase(name: "default"), isModificationDisabled: false)
        return SettingsViewModels(desktop: model, screenSaver: none)
    }

    /// The view models as `WallpaperSettingsViewModelsXPC`, or nil with the
    /// reason logged.
    static func archived(thumbnail: URL) -> AnyObject? {
        guard let models = make(thumbnail: thumbnail) else { return nil }
        let data: Data
        do {
            data = try NSKeyedArchiver.archivedData(
                withRootObject: ArchivedSettingsViewModels(models), requiringSecureCoding: false)
        } catch {
            wallpaperLog("view models: archiving failed: \(error)")
            return nil
        }
        guard let realClass = NSClassFromString("WallpaperSettingsViewModelsXPC") else {
            wallpaperLog("view models: WallpaperSettingsViewModelsXPC is not loaded")
            return nil
        }
        let unarchiver: NSKeyedUnarchiver
        do {
            unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        } catch {
            wallpaperLog("view models: unarchiver failed: \(error)")
            return nil
        }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(realClass, forClassName: "PGRWallpaperSettingsViewModels")
        let decoded = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        if let error = unarchiver.error {
            wallpaperLog("view models: decoding as WallpaperSettingsViewModelsXPC failed: \(error)")
        }
        unarchiver.finishDecoding()
        guard let decoded else {
            wallpaperLog("view models: decoded nothing")
            return nil
        }
        return decoded as AnyObject
    }
}
