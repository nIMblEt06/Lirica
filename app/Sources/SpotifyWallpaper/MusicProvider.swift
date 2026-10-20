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

    /// The provider an app on the Now Playing feed belongs to. BrowserMediaResolver supplies the hostname when this
    /// is a browser; without one the browser session is rejected before it gets here.
    static func of(bundle: String, sourceBundle: String = "", name: String = "",
                   browserHost: String? = nil) -> MusicProvider {
        if let browserHost { return MusicSourcePolicy.provider(forHost: browserHost) }
        switch bundle {
        case "com.spotify.client": return .spotify
        case "com.apple.Music": return .appleMusic
        default:
            let identity = (bundle + " " + sourceBundle + " " + name).lowercased()
            if identity.contains("youtube") && identity.contains("music") { return .youtubeMusic }
            return .other
        }
    }

    /// Browser media sessions often outlive a social clip indefinitely. They are useful while playing, but a paused
    /// 15-second X/Reddit/etc. video must not pin the wallpaper over music that is playing elsewhere.
    static func isTransientBrowserMedia(bundle: String, track: Track) -> Bool {
        guard MusicSourcePolicy.isBrowser(bundle) else { return false }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let socialTitle = title.hasSuffix(" / X") ||
            title.range(of: #"\son\sX:\s*[\"“]"#, options: [.regularExpression, .caseInsensitive]) != nil
        let unattributedShortClip = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            track.duration > 0 && track.duration <= 90
        return socialTitle || unattributedShortClip
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
