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

/// Reads the Spotify desktop app's current track over AppleScript. No login or API key needed.
///
/// AppleScript round-trips are slow (~45 ms for position/state, ~100 ms for everything), so they run on a
/// dedicated thread, never on the main thread. Spotify announces play/pause/skip/seek with a distributed
/// notification, which triggers an immediate check; otherwise a light check runs once a second just to keep the
/// templates' own playback clocks in sync. The full lookup only runs when the track changes.
final class SpotifyMonitor: @unchecked Sendable {
    /// Called on the main thread with the latest track (nil when Spotify is stopped or not running) and the time
    /// (ms since 1970) the position was read.
    var onUpdate: (@MainActor (Track?, Double) -> Void)?

    private let wake = NSCondition()
    private var pending = false
    /// Playback commands queued by the UI; run on the monitor thread, where the NSAppleScripts live.
    private var controls: [SpotifyControl] = []
    private var thread: Thread?

    private static let fullSource = """
    if application "Spotify" is running then
      tell application "Spotify"
        if player state is stopped then return "STOPPED"
        set t to current track
        set d to ASCII character 31
        return (id of t) & d & (name of t) & d & (artist of t) & d & (album of t) & d & (artwork url of t) & d & (duration of t) & d & (player position as text) & d & (player state as text)
      end tell
    end if
    return "NOT_RUNNING"
    """

    private static let lightSource = """
    if application "Spotify" is running then
      tell application "Spotify"
        if player state is stopped then return "STOPPED"
        return (id of current track) & (ASCII character 31) & (player position as text) & (ASCII character 31) & (player state as text)
      end tell
    end if
    return "NOT_RUNNING"
    """

    // Playback controls. Every one is a no-op unless Spotify is already running, so a click on the wallpaper
    // never launches the app.
    private static let playPauseSource = """
    if application "Spotify" is running then tell application "Spotify" to playpause
    """

    private static let nextSource = """
    if application "Spotify" is running then tell application "Spotify" to next track
    """

    private static let previousSource = """
    if application "Spotify" is running then tell application "Spotify" to previous track
    """

    private static func seekSource(_ seconds: Double) -> String {
        """
        if application "Spotify" is running then tell application "Spotify" to set player position to \(String(format: "%.3f", seconds))
        """
    }

    private static func setVolumeSource(_ percent: Double) -> String {
        """
        if application "Spotify" is running then tell application "Spotify" to set sound volume to \(Int(percent.rounded()))
        """
    }

    private static func volumeSource(_ percent: Double) -> String {
        """
        if application "Spotify" is running then
          tell application "Spotify"
            set v to (sound volume) + (\(String(format: "%.1f", percent)))
            if v > 100 then set v to 100
            if v < 0 then set v to 0
            set sound volume to v
          end tell
        end if
        """
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: nil) { [weak self] _ in
            self?.checkNow()
        }
        let t = Thread { [weak self] in self?.run() }
        t.name = "Spotify monitor"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// Ask for a check right away (e.g. Spotify just changed state).
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
        let full = NSAppleScript(source: Self.fullSource)!
        let light = NSAppleScript(source: Self.lightSource)!
        let playPause = NSAppleScript(source: Self.playPauseSource)!
        let next = NSAppleScript(source: Self.nextSource)!
        let previous = NSAppleScript(source: Self.previousSource)!
        full.compileAndReturnError(nil)
        light.compileAndReturnError(nil)
        for script in [playPause, next, previous] { script.compileAndReturnError(nil) }
        var current: Track?

        while true {
            drainControls(playPause, next: next, previous: previous)
            let before = Date().timeIntervalSince1970 * 1000
            var track: Track?
            if let out = execute(light) {
                let p = out.components(separatedBy: "\u{1f}")
                if p.count == 3, let c = current, c.id == p[0] {
                    var t = c
                    t.position = Double(p[1].replacingOccurrences(of: ",", with: ".")) ?? t.position
                    t.isPlaying = p[2] == "playing"
                    track = t
                } else if p.count == 3, let f = execute(full) {
                    track = Self.parseFull(f)  // new track: get title, artist, artwork…
                }
            }
            let after = Date().timeIntervalSince1970 * 1000
            current = track
            let stamp = (before + after) / 2  // the position was read somewhere in the middle of the round-trip
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onUpdate?(track, stamp) }
            }

            // sleep until the next check, or until Spotify tells us something changed
            wake.lock()
            if !pending { wake.wait(until: Date().addingTimeInterval(track == nil ? 2 : 1)) }
            pending = false
            wake.unlock()
        }
    }

    private func execute(_ script: NSAppleScript) -> String? {
        var error: NSDictionary?
        guard let out = script.executeAndReturnError(&error).stringValue, out != "STOPPED", out != "NOT_RUNNING" else { return nil }
        return out
    }

    /// Runs the commands queued since the last drain. Seek and volume scripts depend on their value, so they're
    /// compiled here, on the script's own thread, rather than kept around.
    private func drainControls(_ playPause: NSAppleScript, next: NSAppleScript, previous: NSAppleScript) {
        wake.lock()
        let queued = controls
        controls.removeAll()
        wake.unlock()
        for control in queued {
            var script: NSAppleScript
            switch control {
            case .togglePlayPause: script = playPause
            case .next: script = next
            case .previous: script = previous
            case .seek(let seconds): script = NSAppleScript(source: Self.seekSource(seconds))!
            case .setVolume(let percent): script = NSAppleScript(source: Self.setVolumeSource(percent))!
            case .volumeBy(let percent): script = NSAppleScript(source: Self.volumeSource(percent))!
            }
            if script !== playPause && script !== next && script !== previous { script.compileAndReturnError(nil) }
            script.executeAndReturnError(nil)
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
