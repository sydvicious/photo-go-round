import Foundation

extension Source {
    /// What a person calls this source.
    ///
    /// A folder's or a file's path names it. A Photos album is named by the
    /// description the store keeps beside its identifier — the folders Photos
    /// keeps it in, then its title: `Photos › Trips › Holiday`. In
    /// `PhotosGoRoundAgentAPI` so the agent's log, its dashboard, and a client
    /// reading `X-PGR-Source-Name` all say the same thing.
    public var spokenName: String {
        switch kind {
        case .folder, .file:
            return locator
        case .photosCollection, .photosAsset:
            guard let description else { return "Photos" }
            let title = description.title.isEmpty ? "Untitled album" : description.title
            return (["Photos"] + description.folders + [title]).joined(separator: " › ")
        default:
            return description?.title ?? locator
        }
    }
}
