import Foundation

/// A playback command templates can send from the wallpaper (data-control clicks, Wallpaper.control).
enum SpotifyControl {
    case togglePlayPause
    case next
    case previous
    case seek(Double)      // seconds into the song
    case setVolume(Double) // percent, 0–100
    case volumeBy(Double)  // percent to add, e.g. -6.25
}

/// Reads the current track from the Spotify desktop app or Apple Music over AppleScript. No login or API key needed.
///
/// Whichever player is playing wins; when neither is, the one that's running. Controls go to the same player.
///
/// AppleScript round-trips are slow (~45 ms for position/state, ~100 ms for everything), so they run on a
/// dedicated thread, never on the main thread. Players announce play/pause/skip/seek with distributed
/// notifications, which triggers an immediate check; otherwise a light check runs once a second just to keep the
/// templates' own playback clocks in sync. The full lookup only runs when the track changes.
final class SpotifyMonitor: @unchecked Sendable {
    /// Called on the main thread with the latest track (nil when nothing is playing or running) and the time
    /// (ms since 1970) the position was read.
    var onUpdate: (@MainActor (Track?, Double) -> Void)?

    private let wake = NSCondition()
    private var pending = false
    /// Playback commands queued by the UI; run on the monitor thread, where the NSAppleScripts live.
    private var controls: [SpotifyControl] = []
    private var thread: Thread?

    /// One player's scripts and the track it reported last, so the light check can skip the full lookup.
    private final class Player {
        let app: String
        let light: NSAppleScript
        let full: NSAppleScript
        var current: Track?

        init(app: String, light: String, full: String) {
            self.app = app
            self.light = NSAppleScript(source: light)!
            self.full = NSAppleScript(source: full)!
            self.light.compileAndReturnError(nil)
            self.full.compileAndReturnError(nil)
        }
    }

    private static let spotifyName = "Spotify"
    private static let musicName = "Music"

    private static func fullSource(_ app: String, id: String, artwork: String) -> String {
        """
        if application "\(app)" is running then
          tell application "\(app)"
            if player state is stopped then return "STOPPED"
            set t to current track
            set d to ASCII character 31
            return (\(id)) & d & (name of t) & d & (artist of t) & d & (album of t) & d & (\(artwork)) & d & ((duration of t) * 1000) & d & (player position as text) & d & (player state as text)
          end tell
        end if
        return "NOT_RUNNING"
        """
    }

    private static func lightSource(_ app: String, id: String) -> String {
        """
        if application "\(app)" is running then
          tell application "\(app)"
            if player state is stopped then return "STOPPED"
            return (\(id)) & (ASCII character 31) & (player position as text) & (ASCII character 31) & (player state as text)
          end tell
        end if
        return "NOT_RUNNING"
        """
    }

    // Apple Music has no artwork URL: its cover is read as raw image data, saved to a file, and passed on as a file URL.
    private static let musicArtworkSource = """
    if application "Music" is running then
      tell application "Music"
        if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
      end tell
    end if
    return ""
    """

    private static let spotifyIDExpr = "id of current track"
    private static let musicIDExpr = "\"music:\" & (persistent ID of current track)"

    /// The command for a control, run only if its player is already running, so a click never launches an app.
    private static func controlSource(_ control: SpotifyControl, app: String) -> String {
        let body: String
        switch control {
        case .togglePlayPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .seek(let seconds): body = "set player position to \(String(format: "%.3f", seconds))"
        case .setVolume(let percent): body = "set sound volume to \(Int(percent.rounded()))"
        case .volumeBy(let percent):
            return """
            if application "\(app)" is running then
              tell application "\(app)"
                set v to (sound volume) + (\(String(format: "%.1f", percent)))
                if v > 100 then set v to 100
                if v < 0 then set v to 0
                set sound volume to v
              end tell
            end if
            """
        }
        return """
        if application "\(app)" is running then tell application "\(app)" to \(body)
        """
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            center.addObserver(forName: NSNotification.Name(name), object: nil, queue: nil) { [weak self] _ in
                self?.checkNow()
            }
        }
        let t = Thread { [weak self] in self?.run() }
        t.name = "Player monitor"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// Ask for a check right away (e.g. a player just changed state).
    func checkNow() {
        wake.lock()
        pending = true
        wake.signal()
        wake.unlock()
    }

    /// Queue a playback command (play/pause, skip, seek, volume). Runs before the next read, so the state that
    /// comes back right after reflects it.
    func perform(_ control: SpotifyControl) {
        wake.lock()
        controls.append(control)
        pending = true
        wake.signal()
        wake.unlock()
    }

    private func run() {
        // NSAppleScript objects stay on this one thread
        let spotify = Player(app: Self.spotifyName, light: Self.lightSource(Self.spotifyName, id: Self.spotifyIDExpr),
                             full: Self.fullSource(Self.spotifyName, id: Self.spotifyIDExpr, artwork: "artwork url of t"))
        let music = Player(app: Self.musicName, light: Self.lightSource(Self.musicName, id: Self.musicIDExpr),
                           full: Self.fullSource(Self.musicName, id: Self.musicIDExpr, artwork: "\"\""))
        var playingMusic = false

        while true {
            drainControls(music: playingMusic)
            let before = Date().timeIntervalSince1970 * 1000
            let s = read(spotify), m = read(music)
            let useMusic = m != nil && (s == nil || (m!.isPlaying && !s!.isPlaying))
            let track = useMusic ? m : s
            playingMusic = useMusic
            let after = Date().timeIntervalSince1970 * 1000
            let stamp = (before + after) / 2  // the position was read somewhere in the middle of the round-trip
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onUpdate?(track, stamp) }
            }

            // sleep until the next check, or until a player tells us something changed
            wake.lock()
            if !pending { wake.wait(until: Date().addingTimeInterval(track == nil ? 2 : 1)) }
            pending = false
            wake.unlock()
        }
    }

    private func read(_ player: Player) -> Track? {
        guard let out = execute(player.light) else {
            player.current = nil
            return nil
        }
        let p = out.components(separatedBy: "\u{1f}")
        var track: Track?
        if p.count == 3, let c = player.current, c.id == p[0] {
            var t = c
            t.position = Double(p[1].replacingOccurrences(of: ",", with: ".")) ?? t.position
            t.isPlaying = p[2] == "playing"
            track = t
        } else if p.count == 3, let f = execute(player.full) {
            track = Self.parseFull(f)  // new track: get title, artist, artwork…
            if player.app == Self.musicName, let t = track { track?.artworkURL = musicArtwork(t.id) }
        }
        player.current = track
        return track
    }

    private func execute(_ script: NSAppleScript) -> String? {
        var error: NSDictionary?
        guard let out = script.executeAndReturnError(&error).stringValue, out != "STOPPED", out != "NOT_RUNNING" else { return nil }
        return out
    }

    /// Saves Apple Music's cover for a track to a temporary file and returns its file URL ("" when there's none).
    private func musicArtwork(_ id: String) -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: Self.musicArtworkSource),
              let data = script.executeAndReturnError(&error).data as Data?, !data.isEmpty else { return "" }
        let name = "swmusic-" + String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return "" }
        return url.absoluteString
    }

    /// Runs the commands queued since the last drain on whichever player is playing.
    private func drainControls(music: Bool) {
        wake.lock()
        let queued = controls
        controls.removeAll()
        wake.unlock()
        let app = music ? Self.musicName : Self.spotifyName
        for control in queued {
            NSAppleScript(source: Self.controlSource(control, app: app))?.executeAndReturnError(nil)
        }
    }

    private static func parseFull(_ out: String) -> Track? {
        let p = out.components(separatedBy: "\u{1f}")
        guard p.count == 8 else { return nil }
        return Track(
            id: p[0], title: p[1], artist: p[2], album: p[3], artworkURL: p[4],
            duration: (Double(p[5]) ?? 0) / 1000,
            position: Double(p[6].replacingOccurrences(of: ",", with: ".")) ?? 0,
            isPlaying: p[7] == "playing"
        )
    }
}
