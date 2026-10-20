import AppKit
import CryptoKit
import WebKit

/// Two outputs per screen:
///  - a live, animated layer just above the wallpaper (DesktopLayer), fed state + a 0.1s playback clock;
///    the template's own clock picks the lyric line, so it changes exactly on the line's timestamp
///  - the real wallpaper, a still of the same song, redrawn only when the track/template/settings change
///    (lock screen, Mission Control, and whenever the app isn't running)
@MainActor
final class Engine {
    let store: TemplateStore
    private let paths: Paths
    private let spotify = SpotifyMonitor()
    private let lyricsService: LyricsService
    private let setter: WallpaperSetter
    private(set) lazy var schemeHandler = SchemeHandler(paths: paths, store: store)

    private(set) var track: Track?
    private var pollStamp: Double = 0  // ms since 1970 when `track.position` was read
    private var lyrics = Lyrics.none
    private var candidates: [LyricCandidate] = []
    /// Which source(s) the current lyrics came from, for the menu.
    private(set) var lyricsSourceText = ""
    private var coverData: Data?
    /// Identifies the cover image itself, so templates can tell "new song, same album art" from a new cover.
    private var coverKey = ""
    private var colors: [String: Any] = Palette.extract(from: nil)
    private var loadedTrackID: String?
    private var loadingTrackID: String?

    private var layers: [CGDirectDisplayID: DesktopLayer] = [:]
    private var renderers: [CGDirectDisplayID: ScreenRenderer] = [:]
    /// What each screen's live layer / still last got; a screen is redrawn only when its own key changes.
    private var liveKeys: [CGDirectDisplayID: String] = [:]
    private var stillKeys: [CGDirectDisplayID: String] = [:]
    /// True while the real wallpaper's still is being drawn (ThumbnailService waits for it).
    private(set) var stillRendering = false
    private var generation = 0  // bumped when template code changes on disk
    private var liveEpoch = 0   // bumped on every settings change
    private var stillEpoch = 0  // bumped once settings stop changing
    private var editStamp: Date?
    private var stillDebounce: Task<Void, Never>?
    private var latestTrack: Track?
    private var latestStamp: Double = 0
    /// When Spotify first stopped reporting a track. Skipping or seeking can make a single reading come back empty,
    /// so the wallpaper is only given back once nothing has played for `goneGrace` seconds.
    private var goneSince: Date?
    private static let goneGrace: TimeInterval = 5
    // data services (see the extension at the end)
    let weather = WeatherService()
    private let audio = AudioAnalyzer()
    private lazy var genres = GenreService(paths: paths)
    private var genre = (trackID: "", name: "")
    private var beat = (starting: false, retryAt: Date.distantPast, trackID: "")

    /// Called when the preview in the Customize window should get new state / a clock tick.
    var onStateChange: (() -> Void)?
    var onClock: ((String) -> Void)?
    var onTemplateFilesChanged: (() -> Void)?
    var onMusicSourcesChanged: (() -> Void)?
    /// The finished still for the primary screen (JPEG), the track and template it shows. Feeds the history.
    var onStillRendered: ((Data, NSScreen, Track, String) -> Void)?

    /// Lyrics hidden (screen sharing / Focus Mode): sent as `focus` to the live layers and the still.
    var focus = false {
        didSet {
            guard focus != oldValue else { return }
            liveEpoch += 1
            stillEpoch += 1
            tick()
        }
    }

    var paused: Bool {
        get { UserDefaults.standard.bool(forKey: "paused") }
        set {
            UserDefaults.standard.set(newValue, forKey: "paused")
            if newValue { hideLayers(); setter.restore() }
            invalidate()
        }
    }

    /// Frames per second for the live layer's per-frame animation; 0 = the display's maximum.
    static let refreshRates = [0, 60, 30, 15]
    var refreshRate: Int {
        get { UserDefaults.standard.object(forKey: "refreshRate") as? Int ?? 0 }
        set {
            UserDefaults.standard.set(newValue, forKey: "refreshRate")
            liveEpoch += 1
            tick()
        }
    }

    var nowPlayingText: String {
        guard let t = track else { return "Spotify isn't playing" }
        return "\(t.title) — \(t.artist)"
    }

    // MARK: playback controls on the wallpaper (data-control in templates)

    /// "Wallpaper controls" in Settings. On by default: clicks on a template's controls drive the followed player.
    /// Follows players other than Spotify and Music (browsers, YouTube, any app on the Now Playing feed).
    var otherPlayersEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "otherPlayers") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "otherPlayers")
            spotify.checkNow()
        }
    }

    var controlsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "wallpaperControls") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "wallpaperControls")
            updateControlPanels()
        }
    }

    /// A command from a template: playPause, next, previous, seek (0–1 through the song), volume (0–1) or
    /// volumeBy (±1 = ±100%).
    func performControl(_ command: String, value: Double?) {
        guard controlsEnabled else { return }
        switch command {
        case "playPause": spotify.perform(.togglePlayPause)
        case "next": spotify.perform(.next)
        case "previous": spotify.perform(.previous)
        case "seek":
            guard let t = track, t.duration > 0, let v = value else { return }
            spotify.perform(.seek(min(max(v, 0), 1) * t.duration))
        case "volume":
            guard let v = value else { return }
            spotify.perform(.setVolume(min(max(v, 0), 1) * 100))
        case "volumeBy":
            guard let v = value else { return }
            spotify.perform(.volumeBy(min(max(v, -1), 1) * 100))
        default: break
        }
    }

    /// Keep each layer's native control hit windows in step with the setting. They are below all application windows,
    /// so covered controls naturally stop receiving input without global monitoring or a privacy permission.
    private func updateControlPanels() {
        layers.values.forEach { $0.setControlInteractionEnabled(controlsEnabled) }
    }

    private var lastTrackAt = Date.distantPast
    private static let trackGrace: TimeInterval = 8

    init(store: TemplateStore, paths: Paths) {
        self.store = store
        self.paths = paths
        spotify.nowPlaying = NowPlayingAdapter(resources: paths.resources)
        lyricsService = LyricsService(paths: paths)
        setter = WallpaperSetter(paths: paths)
    }

    private lazy var controlBridge = ControlBridge(engine: self)

    func makeWebConfiguration(throttleWhenHidden: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "sw")
        config.userContentController.add(controlBridge, name: "swCommand")
        if !throttleWhenHidden { config.preferences.inactiveSchedulingPolicy = .none }
        return config
    }

    func start() {
        schemeHandler.cover = { [weak self] in self?.coverData }
        // Spotify is read on its own thread; each reading lands here
        spotify.onUpdate = { [weak self] track, stamp in
            guard let self else { return }
            if track == nil, self.latestTrack != nil {
                let since = self.goneSince ?? Date()
                self.goneSince = since
                if Date().timeIntervalSince(since) < Self.goneGrace { return }  // probably a skip/seek blip: hold on
            }
            self.goneSince = nil
            self.latestTrack = track
            self.latestStamp = stamp
            self.tick()
        }
        spotify.onSourcesChanged = { [weak self] in self?.onMusicSourcesChanged?() }
        spotify.start()
        startDataServices()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTemplateEdits() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Trace.log("space changed: reapplying still wallpaper")
                self?.setter.reapply()
                self?.layers.values.forEach { $0.spaceChanged() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // a screen's template changed: its keys change with it, so only that screen is redrawn
        NotificationCenter.default.addObserver(
            forName: TemplateStore.activeChangedNotification, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func shutdown() {
        hideLayers()
        spotify.nowPlaying?.shutdown()
        setter.restore()
    }

    /// Redraw everything, e.g. after switching templates.
    func invalidate() {
        liveKeys.removeAll()
        stillKeys.removeAll()
        tick()
    }

    /// Re-evaluate the followed player immediately after a source or site rule changes.
    func musicSourcesChanged() {
        spotify.checkNow()
    }

    /// The template `screen` shows: its own if it has one, else the default.
    func templateID(for screen: NSScreen) -> String {
        store.activeID(for: displayID(screen))
    }

    private func template(for screen: NSScreen) -> WallpaperTemplate? {
        store.template(templateID(for: screen)) ?? store.active
    }

    /// One key per screen; a screen whose key changed needs redrawing. Pure, for tests.
    nonisolated static func screenKeys(trackID: String, templates: [CGDirectDisplayID: String], generation: Int,
                                       epoch: Int) -> [CGDirectDisplayID: String] {
        templates.mapValues { "\(trackID)|\($0)|\(generation)|\(epoch)" }
    }

    /// Screens in `new` whose key differs from `old`, in display order.
    nonisolated static func changedScreens(_ new: [CGDirectDisplayID: String], from old: [CGDirectDisplayID: String])
        -> [CGDirectDisplayID] {
        new.keys.filter { new[$0] != old[$0] }.sorted()
    }

    /// Settings changed: the live layer updates immediately, the still once the sliders stop moving.
    func paramsChanged() {
        liveEpoch += 1
        tick()
        stillDebounce?.cancel()
        stillDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.stillEpoch += 1
            self.tick()
        }
    }

    private func screensChanged() {
        layers.values.forEach { $0.close() }
        layers.removeAll()
        renderers.values.forEach { $0.close() }
        renderers.removeAll()
        updateControlPanels()
        invalidate()
    }

    // MARK: main loop

    private func tick() {
        let previousID = track?.id
        // a track that drops out for a moment (a browser pausing, a player restarting) keeps the wallpaper up for a
        // while; hiding it would also hand the desktop back to the system picture and then pop the wallpaper again
        if let fresh = latestTrack {
            lastTrackAt = Date()
            track = fresh
        } else if Date().timeIntervalSince(lastTrackAt) >= Self.trackGrace {
            track = nil
        }
        if track?.id != previousID {
            Trace.log("track: \(track.map { String($0.id.prefix(60)) } ?? "none")")
        }
        pollStamp = latestStamp
        updateBeatCapture()
        guard let t = track else {
            hideLayers()
            setter.restore()
            liveKeys.removeAll()
            stillKeys.removeAll()
            if previousID != nil { onStateChange?() }
            return
        }
        if t.id != loadedTrackID && t.id != loadingTrackID {
            loadingTrackID = t.id
            Task { await load(t) }
        }
        guard loadedTrackID == t.id, !paused, store.active != nil else { return }

        // each screen's template
        var screenTemplates: [CGDirectDisplayID: WallpaperTemplate] = [:]
        for screen in NSScreen.screens { screenTemplates[displayID(screen)] = template(for: screen) }
        let ids = screenTemplates.mapValues(\.id)

        // live layers: only the screens whose template/track/settings changed get new state
        syncLayers(screenTemplates)
        let live = Self.screenKeys(trackID: t.id, templates: ids, generation: generation, epoch: liveEpoch)
        let liveChanged = Self.changedScreens(live, from: liveKeys)
        for id in liveChanged {
            guard let layer = layers[id], let template = screenTemplates[id] else { continue }
            liveKeys[id] = live[id]
            var payload = statePayload(for: NSScreen.screens.first { displayID($0) == id })
            payload["params"] = store.values(template.id)
            payload["fps"] = refreshRate
            payload["focus"] = focus
            layer.sendState(jsonString(payload))
        }
        if !liveChanged.isEmpty { onStateChange?() }
        let clock = jsonString(["position": t.position, "isPlaying": t.isPlaying, "stamp": pollStamp])
        layers.values.forEach { $0.sendClock(clock); $0.show() }
        updateControlPanels()
        onClock?(clock)

        // real wallpaper still: only the screens whose key changed are redrawn
        let still = Self.screenKeys(trackID: t.id, templates: ids, generation: generation, epoch: stillEpoch)
        let stillChanged = Self.changedScreens(still, from: stillKeys)
        if !stillChanged.isEmpty && !stillRendering {
            for id in stillChanged { stillKeys[id] = still[id] }
            let screens = NSScreen.screens.filter { stillChanged.contains(displayID($0)) }
            Task { await renderStill(screens) }
        }
    }

    /// Each screen's layer shows that screen's template (a layer only reloads when its own URL changes).
    private func syncLayers(_ templates: [CGDirectDisplayID: WallpaperTemplate]) {
        for screen in NSScreen.screens {
            let id = displayID(screen)
            guard let template = templates[id] else { continue }
            if layers[id]?.frame != screen.frame {
                layers[id]?.close()
                let layer = DesktopLayer(screen: screen, configuration: makeWebConfiguration(throttleWhenHidden: true))
                layers[id] = layer
                liveKeys[id] = nil
            }
            var url = URLComponents(url: template.url, resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "v", value: String(generation)), .init(name: "live", value: "1")]
            layers[id]?.load(url.url!)
        }
    }

    private func hideLayers() {
        layers.values.forEach { $0.hide() }
        updateControlPanels()
    }

    private func load(_ t: Track) async {
        fetchGenre(t)
        async let cover = download(t.artworkURL)
        async let found = lyricsService.candidates(for: t)
        let (c, cs) = await (cover, found)
        coverData = c
        coverKey = c.map { SHA256.hash(data: $0).prefix(8).map { String(format: "%02x", $0) }.joined() } ?? ""
        colors = Palette.extract(from: c)
        candidates = cs
        loadedTrackID = t.id
        if loadingTrackID == t.id { loadingTrackID = nil }
        applyLyrics()
    }

    // MARK: lyrics source & timing (chosen per song, remembered)

    /// Sources that have lyrics for the current song, and whether each is synced.
    var lyricsSources: [(name: String, synced: Bool)] { candidates.map { ($0.source, $0.synced) } }

    /// "Combined" (consensus timing from every synced source) or one source's name.
    var lyricsChoice: String {
        get { loadedTrackID.flatMap { UserDefaults.standard.string(forKey: "lyricsChoice." + $0) } ?? "Combined" }
        set {
            guard let id = loadedTrackID else { return }
            UserDefaults.standard.set(newValue, forKey: "lyricsChoice." + id)
            applyLyrics()
        }
    }

    /// Seconds added to every timestamp: positive shows lines later, negative earlier.
    var lyricsOffset: Double {
        get { loadedTrackID.map { UserDefaults.standard.double(forKey: "lyricsOffset." + $0) } ?? 0 }
        set {
            guard let id = loadedTrackID else { return }
            UserDefaults.standard.set(newValue, forKey: "lyricsOffset." + id)
            applyLyrics()
        }
    }

    func refetchLyrics() {
        guard let t = track, t.id == loadedTrackID else { return }
        Task {
            candidates = await lyricsService.candidates(for: t, refresh: true)
            applyLyrics()
        }
    }

    private func applyLyrics() {
        var (resolved, source) = LyricsService.resolve(candidates, choice: lyricsChoice, duration: track?.duration ?? 0)
        let offset = lyricsOffset
        if offset != 0 { for i in resolved.lines.indices { resolved.lines[i].t += offset } }
        lyrics = resolved
        lyricsSourceText = source
        liveEpoch += 1
        stillEpoch += 1
        tick()
    }

    private func download(_ url: String) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        return try? await URLSession.shared.data(from: u).0
    }

    // MARK: still for the real wallpaper

    private func renderStill(_ screens: [NSScreen]) async {
        stillRendering = true
        defer { stillRendering = false }
        let trackID = track?.id
        for screen in screens {
            guard let template = template(for: screen) else { continue }
            var url = URLComponents(url: template.url, resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "v", value: String(generation))]
            let id = displayID(screen), size = screen.frame.size
            if renderers[id]?.size != size {
                renderers[id]?.close()
                renderers[id] = ScreenRenderer(size: size, configuration: makeWebConfiguration())
            }
            var payload = statePayload(for: screen)
            payload["params"] = store.values(template.id)
            payload["focus"] = focus
            guard let image = await renderers[id]?.render(url: url.url!, payload: payload) else { continue }
            let jpeg = await Task.detached { jpegData(image) }.value
            // the song may have changed or stopped while drawing
            guard let jpeg, !paused, track?.id == trackID, track != nil else { return }
            setter.show(jpeg, on: screen)
            if let t = track, screen == NSScreen.screens.first { onStillRendered?(jpeg, screen, t, template.id) }
        }
    }

    // MARK: state sent to templates

    func statePayload(for screen: NSScreen? = NSScreen.main) -> [String: Any] {
        let screenInfo: [String: Any] = [
            "width": screen?.frame.width ?? 1512, "height": screen?.frame.height ?? 982,
            "scale": screen?.backingScaleFactor ?? 2,
        ]
        guard let t = track, loadedTrackID == t.id else { return sample(screenInfo) }
        let safeID = t.id.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        var payload: [String: Any] = [
            "track": ["id": t.id, "title": t.title, "artist": t.artist, "album": t.album,
                      "cover": "sw://app/cover/\(safeID).jpg", "coverKey": coverKey, "duration": t.duration,
                      "position": t.position, "isPlaying": t.isPlaying, "stamp": pollStamp,
                      "genre": genre.trackID == t.id ? genre.name : ""],
            "lyrics": lyricsPayload(lyrics, index: lyrics.index(at: t.position)),
            "colors": colors,
            "screen": screenInfo,
        ]
        payload["weather"] = weather.current?.json
        return payload
    }

    private lazy var sampleColors: [String: Any] =
        Palette.extract(from: try? Data(contentsOf: paths.web.appendingPathComponent("ui/sample-cover.jpg")))

    /// Shown in the preview when Spotify isn't playing.
    private func sample(_ screenInfo: [String: Any]) -> [String: Any] {
        let lines = ["Streetlights hum a song we used to know", "Your jacket on my shoulders, walking slow",
                     "The city sleeps but we're still wide awake", "Counting every chance we didn't take",
                     "", "Stay a little longer, stay till morning light",
                     "We can fold the stars up, keep them out of sight", "Stay a little longer, it's alright"]
        var sampleLyrics = Lyrics(lines: lines.enumerated().map { LyricLine(t: 52.0 + Double($0.offset) * 6, text: $0.element) },
                                  synced: true)
        sampleLyrics.lines[3].translation = "Contando cada oportunidad que no tomamos"
        return [
            "track": ["id": "sample", "title": "Till Morning Light", "artist": "Sample Artist",
                      "album": "Preview Sessions", "cover": "sw://app/ui/sample-cover.jpg",
                      "duration": 214.0, "position": 71.0, "isPlaying": false,
                      "stamp": Date().timeIntervalSince1970 * 1000, "genre": "Pop"],
            "lyrics": lyricsPayload(sampleLyrics, index: 3),
            "colors": sampleColors,
            "screen": screenInfo,
            "weather": weather.current?.json ?? Self.sampleWeather,
        ]
    }

    // MARK: live reload while editing a template's code

    private func checkTemplateEdits() {
        let stamp = store.userTemplatesStamp()
        if let old = editStamp, stamp > old {
            store.reload()
            generation += 1
            onTemplateFilesChanged?()
            invalidate()
        }
        editStamp = stamp
    }
}

// MARK: - data services: genre, translations/duets in the payload, weather, beat sync

extension Engine {
    private static var sampleWeather: [String: Any] {
        let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000, now = Date().timeIntervalSince1970 * 1000
        let sunrise = midnight + 6.5 * 3_600_000, sunset = midnight + 19 * 3_600_000
        return ["condition": "clouds", "temperature": 18.5, "isDay": now >= sunrise && now < sunset, "sunrise": sunrise, "sunset": sunset]
    }

    private func lyricsPayload(_ l: Lyrics, index: Int) -> [String: Any] {
        var out: [String: Any] = [
            "lines": l.lines.map { line -> [String: Any] in
                var d: [String: Any] = ["t": line.t, "text": line.text]
                if let tr = line.translation { d["translation"] = tr }
                if let s = line.singer { d["singer"] = s }
                return d
            },
            "index": index, "synced": l.synced, "hasTranslation": l.hasTranslation,
        ]
        if !l.singers.isEmpty { out["singers"] = l.singers }
        return out
    }

    private func startDataServices() {
        weather.onChange = { [weak self] in
            guard let self else { return }
            self.liveEpoch += 1
            self.stillEpoch += 1
            self.tick()
        }
        weather.start()
        audio.onBeat = { [weak self] json in self?.sendBeat(json) }
        audio.onStopped = { [weak self] in
            self?.beat.retryAt = Date().addingTimeInterval(5)
            self?.updateBeatCapture()
        }
    }

    /// Looked up alongside the cover and lyrics but never waited for: if it lands after the song loaded, redraw.
    private func fetchGenre(_ t: Track) {
        Task {
            let name = await genres.genre(artist: t.artist, title: t.title)
            genre = (t.id, name)
            if loadedTrackID == t.id, !name.isEmpty {
                liveEpoch += 1
                stillEpoch += 1
                tick()
            }
        }
    }

    /// "Use Weather" in the menu.
    var useWeather: Bool {
        get { weather.enabled }
        set { weather.enabled = newValue }
    }

    // MARK: beat sync

    /// "Sync to the Beat" in the menu. Off by default: listening to Spotify needs Screen Recording permission.
    var beatSync: Bool {
        get { UserDefaults.standard.bool(forKey: "beatSync") }
        set {
            UserDefaults.standard.set(newValue, forKey: "beatSync")
            guard newValue else { return updateBeatCapture() }
            beat.retryAt = .distantPast
            Task {
                if await AudioAnalyzer.requestAccess() { updateBeatCapture() } else { beatPermissionMissing() }
            }
        }
    }

    /// Capture runs only while there is something to hear and someone to show it to.
    private func updateBeatCapture() {
        let want = beatSync && !paused && track?.isPlaying == true
        if let id = track?.id, id != beat.trackID { beat.trackID = id; audio.reset() }
        if !want {
            audio.stop()
            return
        }
        guard !audio.isRunning, !beat.starting, beat.retryAt < Date() else { return }
        beat.starting = true
        Task {
            do {
                try await audio.start()
            } catch {
                beat.retryAt = Date().addingTimeInterval(15)
                if !CGPreflightScreenCaptureAccess() { beatPermissionMissing() }
            }
            beat.starting = false
            updateBeatCapture()  // things may have changed while starting
        }
    }

    private func sendBeat(_ json: String) {
        guard !paused else { return }
        layers.values.forEach { $0.sendBeat(json) }
    }

    private func beatPermissionMissing() {
        UserDefaults.standard.set(false, forKey: "beatSync")
        audio.stop()
        let alert = NSAlert()
        alert.messageText = "Sync to the Beat needs Screen Recording"
        alert.informativeText = """
            Lirica listens to Spotify's sound to find the beat; macOS files that under screen recording. \
            Nothing is recorded or saved.

            Turn on Lirica in System Settings › Privacy & Security › Screen & System Audio Recording, \
            then choose Sync to the Beat again (macOS may ask you to reopen the app first).
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
