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

    /// The provider an app on the Now Playing feed belongs to. The feed identifies a browser, not its tab. When the
    /// user chose YouTube Music as the default, browser playback is therefore treated as YouTube Music; otherwise it
    /// remains under Other Apps. Standalone YouTube Music clients identify themselves directly.
    static func of(bundle: String) -> MusicProvider {
        switch bundle {
        case "com.spotify.client": return .spotify
        case "com.apple.Music": return .appleMusic
        default:
            let id = bundle.lowercased()
            if id.contains("youtube") && id.contains("music") { return .youtubeMusic }
            if defaultProvider == .youtubeMusic && isBrowser(id) { return .youtubeMusic }
            return .other
        }
    }

    private static func isBrowser(_ id: String) -> Bool {
        ["browser", "safari", "chrome", "chromium", "firefox", "edgemac", "brave", "opera", "vivaldi", "orion"]
            .contains { id.contains($0) }
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
