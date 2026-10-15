import Foundation

/// The music apps the wallpaper can follow. When several are playing, the default one wins; the rest are checked in
/// the usual order after it.
enum MusicProvider: String, CaseIterable {
    case spotify, appleMusic, youtubeMusic, other

    var title: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        case .youtubeMusic: "YouTube Music"
        case .other: "Other Apps"
        }
    }

    /// The provider an app on the Now Playing feed belongs to. Browsers count as Other Apps: the feed doesn't say
    /// which site is playing, so YouTube Music in a browser is only recognised as Other Apps.
    static func of(bundle: String) -> MusicProvider {
        switch bundle {
        case "com.spotify.client": .spotify
        case "com.apple.Music": .appleMusic
        default: bundle.lowercased().contains("youtube") && bundle.lowercased().contains("music") ? .youtubeMusic : .other
        }
    }

    /// The default provider, stored in the Settings tab. Spotify until you choose otherwise.
    static var defaultProvider: MusicProvider {
        get { UserDefaults.standard.string(forKey: "musicPriority").flatMap(MusicProvider.init(rawValue:)) ?? .spotify }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "musicPriority") }
    }

    /// Checked in this order: the default first, then the rest as listed in the enum.
    static var priority: [MusicProvider] {
        let first = defaultProvider
        return [first] + allCases.filter { $0 != first }
    }
}
