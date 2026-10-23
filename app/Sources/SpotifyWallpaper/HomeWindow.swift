import AppKit
import WebKit

/// Home ("Lirica"), the app's main window, as a web UI (ui/home.html):
///  - Wallpaper: a live preview of the template on a display, its settings in a floating inspector, a shelf of
///    recent and favourite templates, and "Browse all" (a categorised gallery, or a record-crate view)
///  - Displays: the real display arrangement; drop a template on a screen to set that screen only
///  - History: the History Wall (ui/history.html, embedded; its native side is HistoryBridge)
///  - Lyrics: lyrics source and timing for the current song
///  - Settings: everything app-wide (the menu bar menu keeps only everyday actions)
/// Only the preview is a live template; everything else shows ThumbnailService's stills.
@MainActor
final class HomeWindowController: NSWindowController, WKScriptMessageHandler, NSWindowDelegate {
    private static let barHeight: CGFloat = 52
    private let engine: Engine
    private let store: TemplateStore
    private let paths: Paths
    private let thumbs: ThumbnailService
    private let historyBridge: HistoryBridge
    private var webView: WKWebView!
    private var strip: DragStrip!
    private var ready = false
    /// Where to go once the page has loaded (tab, template sheet…).
    private var pendingNavigation: [String: Any] = [:]
    private var thumbsDebounce: Task<Void, Never>?
    private var lastVisible: Bool?
    private var recovery: ReloadOnCrash?

    var onOpenBuilder: ((String?) -> Void)?
    var onShareCard: (() -> Void)?
    /// App-wide settings for the Settings tab, a change to one, and its buttons (all live in AppDelegate).
    var settings: (() -> [String: Any])?
    var onSetting: ((String, Any?) -> Void)?
    var onSettingAction: ((String) -> Void)?
    var installer: TemplateInstaller?

    init(engine: Engine, store: TemplateStore, paths: Paths, thumbs: ThumbnailService, history: HistoryStore) {
        self.engine = engine
        self.store = store
        self.paths = paths
        self.thumbs = thumbs
        historyBridge = HistoryBridge(history: history, store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Lirica"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)  // the page is always the frosted dark theme
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        window.setFrameAutosaveName("Home")
        if !window.setFrameUsingName("Home") { window.center() }
        super.init(window: window)
        window.delegate = self

        // Throttled when hidden; the page also pauses its live preview then (see `visibilityChanged`).
        let config = engine.makeWebConfiguration(throttleWhenHidden: true)
        // a weak proxy: the user content controller retains its handlers, so adding `self` would
        // keep this window (and its web view) alive after it closes
        config.userContentController.add(WeakScriptMessageHandler(self), name: "app")
        let container = NSView(frame: window.contentView!.bounds)
        webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        // The page fills the (transparent) title bar and would swallow drags, so a drag strip sits over it.
        strip = DragStrip(frame: NSRect(x: 0, y: container.bounds.height - Self.barHeight,
                                        width: container.bounds.width, height: Self.barHeight))
        strip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(strip)
        window.contentView = container

        historyBridge.send = { [weak self] msg in self?.send(["type": "history", "msg": msg]) }
        historyBridge.window = { [weak self] in self?.window }
        // the page says "ready" again after a reload, which resends everything
        recovery = ReloadOnCrash(webView)
        recovery?.onReload = { [weak self] in self?.ready = false; self?.lastVisible = nil }
        webView.load(URLRequest(url: URL(string: "sw://app/ui/home.html")!))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: showing

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.centerTrafficLights(inBarOfHeight: Self.barHeight)
        if ready { pushState() }
        visibilityChanged()
    }

    /// Opens Home on a tab: "wallpaper", "gallery", "displays", "history", "lyrics" or "settings".
    func show(tab: String) {
        navigate(["tab": tab])
        show()
    }

    /// Opens Home with a template's sheet (preview, settings, Use as Wallpaper), e.g. right after installing it.
    func showTemplate(_ id: String) {
        navigate(["sheet": id])
        show()
    }

    private func navigate(_ nav: [String: Any]) {
        if ready { sendInit(nav) } else { pendingNavigation.merge(nav) { _, new in new } }
    }

    func snapshot() async -> NSImage? { try? await webView.takeSnapshot(configuration: nil) }

    func windowDidResize(_ notification: Notification) { window?.centerTrafficLights(inBarOfHeight: Self.barHeight) }
    func windowDidExitFullScreen(_ notification: Notification) { window?.centerTrafficLights(inBarOfHeight: Self.barHeight) }
    func windowDidChangeOcclusionState(_ notification: Notification) { visibilityChanged() }
    func windowDidMiniaturize(_ notification: Notification) { visibilityChanged() }
    func windowDidDeminiaturize(_ notification: Notification) { visibilityChanged() }
    func windowWillClose(_ notification: Notification) { visibilityChanged(closing: true) }

    private var isShowing: Bool {
        guard let w = window else { return false }
        return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
    }

    /// The live preview pauses while the window can't be seen.
    private func visibilityChanged(closing: Bool = false) {
        let visible = !closing && isShowing
        guard ready, visible != lastVisible else { return }
        lastVisible = visible
        send(["type": "visibility", "visible": visible])
        if visible { pushState() }
    }

    // MARK: messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let id = body["id"] as? String ?? ""
        switch type {
        case "titlebarHoles":
            let rects = body["rects"] as? [[String: Double]] ?? []
            strip.holes = rects.map { NSRect(x: $0["x"] ?? 0, y: $0["y"] ?? 0, width: $0["w"] ?? 0, height: $0["h"] ?? 0) }
        case "ready":
            ready = true
            lastVisible = nil
            sendInit(pendingNavigation)
            pendingNavigation = [:]
            visibilityChanged()
        case "history":
            if let msg = body["msg"] as? [String: Any] { historyBridge.handle(msg) }
        case "activate":
            guard store.template(id) != nil else { return }
            let display = (body["display"] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
            store.setActive(id, display: display)
            engine.invalidate()
            pushState()
        case "setParam":
            guard let key = body["key"] as? String, let value = body["value"] else { return }
            store.setValue(id, key: key, value: value)
            if isOnScreen(id) { engine.paramsChanged() }
            scheduleThumbs()
        case "reset":
            store.reset(id)
            if isOnScreen(id) { engine.invalidate() }
            sendInit()
        case "favorite":
            store.setFavorite(id, body["on"] as? Bool ?? false)
            pushState()
        case "duplicate":
            if let newID = store.duplicate(id) {
                sendInit(["select": newID])
                if let t = store.template(newID) { NSWorkspace.shared.activateFileViewerSelecting([t.dir.appendingPathComponent("index.html")]) }
            }
        case "openFolder":
            if let t = store.template(id), !t.builtin {
                NSWorkspace.shared.activateFileViewerSelecting([t.dir.appendingPathComponent("index.html")])
            } else {
                NSWorkspace.shared.open(paths.userTemplates)
            }
        case "delete":
            delete(id)
        case "newTemplate":
            onOpenBuilder?(nil)
        case "openBuilder":
            onOpenBuilder?(id.isEmpty ? nil : id)
        case "exportTemplate":
            installer?.export(id, from: window)
        case "importTemplate":
            installer?.importWithPanel(from: window)
        case "reload":
            store.reload()
            thumbs.invalidateAll()
            engine.invalidate()
            sendInit()
        case "share":
            onShareCard?()
        case "lyricsSource":
            if let v = body["value"] as? String { engine.lyricsChoice = v }
            pushState()
        case "lyricsNudge":
            if let d = body["delta"] as? Double { engine.lyricsOffset = ((engine.lyricsOffset + d) * 100).rounded() / 100 }
            pushState()
        case "lyricsReset":
            engine.lyricsOffset = 0
            pushState()
        case "lyricsRefetch":
            engine.refetchLyrics()
        case "setting":
            if let key = body["key"] as? String { onSetting?(key, body["value"]) }
        case "settingAction":
            if let action = body["action"] as? String { onSettingAction?(action) }
        case "pref":
            if let key = body["key"] as? String { UserDefaults.standard.set(body["value"], forKey: "home." + key) }
        default:
            break
        }
    }

    /// Shown on any screen right now (its settings then redraw the wallpaper).
    private func isOnScreen(_ id: String) -> Bool {
        store.activeID == id || NSScreen.screens.contains { engine.templateID(for: $0) == id }
    }

    private func delete(_ id: String) {
        guard let t = store.template(id), !t.builtin, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(t.name)” to the Trash?"
        alert.informativeText = "Its folder in your templates folder goes to the Trash; you can put it back from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    try FileManager.default.trashItem(at: t.dir, resultingItemURL: nil)
                } catch {
                    TemplateInstaller.alert("Couldn't delete “\(t.name)”", error.localizedDescription)
                    return
                }
                self.store.reload()
                self.engine.invalidate()
                self.sendInit()
            }
        }
    }

    // MARK: messages to the page

    func sendInit(_ extra: [String: Any] = [:]) {
        guard ready else { return }
        var values: [String: Any] = [:]
        for t in store.templates { values[t.id] = store.values(t.id) }
        var msg = status()
        msg["type"] = "init"
        msg["templates"] = store.templates.map { t -> [String: Any] in
            var s = t.summary
            s["category"] = store.category(t.id)
            return s
        }
        msg["values"] = values
        msg["prefs"] = ["galleryMode": UserDefaults.standard.string(forKey: "home.galleryMode") ?? "grid"]
        msg.merge(extra) { _, new in new }
        send(msg)
    }

    /// Song, lyrics, displays and which template each shows. Cheap: no template list.
    func pushState() {
        guard ready, isShowing else { return }
        var msg = status()
        msg["type"] = "state"
        send(msg)
    }

    func pushClock(_ json: String) {
        guard ready, isShowing else { return }
        webView.evaluateJavaScript("window.App && App.receive({type: 'clock', clock: \(json)})")
    }

    /// Template code changed on disk (live reload while editing).
    func templateFilesChanged() {
        guard ready else { return }
        sendInit()
        send(["type": "reloadPreview"])
    }

    /// The template on a screen changed (here, the Quick Switcher, or the menu).
    func activeChanged() { pushState() }

    /// New wallpaper saved, history cleared or switched off.
    func historyChanged() {
        guard ready, isShowing else { return }
        historyBridge.sendInit()
    }

    /// Thumbnails pick up settings changes once the sliders stop moving.
    private func scheduleThumbs() {
        thumbsDebounce?.cancel()
        thumbsDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.send(["type": "thumbs", "thumbs": self.thumbs.versions()])
        }
    }

    private func status() -> [String: Any] {
        let screens = NSScreen.screens
        let top = screens.first?.frame.maxY ?? 0
        let displays: [[String: Any]] = screens.enumerated().map { i, s in
            [
                "id": Int(displayID(s)), "name": s.localizedName, "main": i == 0,
                // top-left origin, in points, relative to the menu-bar screen
                "x": s.frame.minX, "y": top - s.frame.maxY, "width": s.frame.width, "height": s.frame.height,
                "scale": s.backingScaleFactor, "template": engine.templateID(for: s),
            ]
        }
        var overrides: [String: String] = [:]
        for (d, id) in store.displayOverrides { overrides[String(d)] = id }
        return [
            "state": engine.statePayload(for: screens.first),
            "displays": displays,
            "defaultID": store.activeID,
            "overrides": overrides,
            "recents": store.recentIDs,
            "favorites": store.favoriteIDs.sorted(),
            "settings": settings?() ?? [:],
            "thumbs": thumbs.versions(),
            "lyrics": [
                "playing": engine.track != nil,
                "sources": engine.lyricsSources.map { ["name": $0.name, "synced": $0.synced] },
                "choice": engine.lyricsChoice,
                "offset": engine.lyricsOffset,
                "from": engine.lyricsSourceText,
            ] as [String: Any],
        ]
    }

    private func send(_ message: [String: Any]) {
        webView.evaluateJavaScript("window.App && App.receive(\(jsonString(message)))")
    }
}
