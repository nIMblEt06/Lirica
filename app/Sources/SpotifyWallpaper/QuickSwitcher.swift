import AppKit
import WebKit

/// The Quick Switcher (⌃⌥⌘W): a frosted panel over the desktop to search templates and run actions.
/// ↩ applies a template to every screen, ⌥↩ to the screen under the pointer, ⌘↩ opens it in Home.
/// The panel takes the keyboard while it's open; closing it hands focus back to the app you were in.
@MainActor
final class QuickSwitcher: NSObject, WKScriptMessageHandler, NSWindowDelegate {
    private let engine: Engine
    private let store: TemplateStore
    private var panel: SwitcherPanel?
    private var webView: WKWebView?
    private var recovery: ReloadOnCrash?
    private var ready = false
    private var waitingToShow = false
    private var closing = false
    private var previousApp: NSRunningApplication?
    private static let size = NSSize(width: 640, height: 460)
    private static let corner: CGFloat = 16

    // Provided by AppDelegate.
    var onShareCard: (() -> Void)?
    var onToggleFocus: (() -> Void)?
    var isFocusOn: (() -> Bool)?
    var onOpenHistory: (() -> Void)?
    /// ⌘↩ on a template (its id), or the "Open Lirica" action (nil).
    var onOpenHome: ((String?) -> Void)?
    /// The thumbnail for a template; ThumbnailService can supply versioned URLs. A 404 shows a category tile.
    var thumbURL: ((String) -> String)?

    init(engine: Engine, store: TemplateStore) {
        self.engine = engine
        self.store = store
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true && !closing }

    func toggle() { isVisible ? close(restoringFocus: true) : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        closing = false
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let screen = Self.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        if let area = screen?.visibleFrame {
            // centred, a little above the middle (like Spotlight)
            panel.setFrameOrigin(NSPoint(x: (area.midX - Self.size.width / 2).rounded(),
                                         y: (area.minY + area.height * 0.56 - Self.size.height / 2).rounded()))
        }
        sendOpen()
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        if ready { fadeIn() } else { waitingToShow = true }
    }

    /// `restoringFocus`: give the keyboard back to the app that had it (not when the user clicked elsewhere,
    /// or when an action opened one of our windows).
    func close(restoringFocus: Bool) {
        guard let panel, panel.isVisible, !closing else { return }
        closing = true
        waitingToShow = false
        let previous = restoringFocus ? previousApp : nil
        previousApp = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.reduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing else { return }
                self.closing = false
                panel.orderOut(nil)
            }
        })
        if let previous, !previous.isTerminated { previous.activate() }
    }

    private func fadeIn() {
        waitingToShow = false
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.reduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
        panel.invalidateShadow()
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    // MARK: window

    private func makePanel() -> SwitcherPanel {
        let rect = NSRect(origin: .zero, size: Self.size)
        let p = SwitcherPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.appearance = NSAppearance(named: .darkAqua)
        p.delegate = self
        p.onCancel = { [weak self] in self?.close(restoringFocus: true) }

        // frosted glass behind a transparent page, clipped to the panel's rounded shape
        let container = NSView(frame: rect)
        let glass = NSVisualEffectView(frame: rect)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = Self.roundedMask(radius: Self.corner)
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        let config = engine.makeWebConfiguration()
        config.userContentController.add(WeakScriptMessageHandler(self), name: "app")
        let web = WKWebView(frame: rect, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.wantsLayer = true
        web.layer?.cornerRadius = Self.corner
        web.layer?.masksToBounds = true
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
        p.contentView = container
        recovery = ReloadOnCrash(web)
        web.load(URLRequest(url: URL(string: "sw://app/ui/switcher.html")!))
        panel = p
        webView = web
        return p
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Clicking anywhere outside closes it (focus has already gone where the click went).
    func windowDidResignKey(_ notification: Notification) { close(restoringFocus: false) }

    // MARK: bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let id = body["id"] as? String ?? ""
        switch type {
        case "ready":
            ready = true
            if panel?.isVisible == true { sendOpen() }
            if waitingToShow { fadeIn() }
        case "close":
            close(restoringFocus: true)
        case "apply":
            apply(id, onlyScreenUnderMouse: body["scope"] as? String == "mouse")
        case "home":
            guard store.template(id) != nil else { return }
            close(restoringFocus: false)
            onOpenHome?(id)
        case "action":
            runAction(id)
        default:
            break
        }
    }

    private func apply(_ id: String, onlyScreenUnderMouse: Bool) {
        guard let t = store.template(id) else { return }
        let target = onlyScreenUnderMouse && NSScreen.screens.count > 1 ? Self.screenUnderMouse() : nil
        close(restoringFocus: true)
        store.setActive(id, display: target.map(displayID))
        let detail: String
        if let target { detail = "On \(target.localizedName) only" }
        else { detail = NSScreen.screens.count > 1 ? "On all screens" : "Now on your desktop" }
        HUD.show(title: t.name, detail: detail)
    }

    private func runAction(_ id: String) {
        switch id {
        case "share":
            close(restoringFocus: true)
            onShareCard?()
        case "focus":
            close(restoringFocus: true)
            onToggleFocus?()
        case "earlier", "later":
            // stays open so it can be pressed again; the row shows the new offset
            guard engine.track != nil, !engine.lyricsSources.isEmpty else { return }
            engine.lyricsOffset = ((engine.lyricsOffset + (id == "earlier" ? -0.5 : 0.5)) * 100).rounded() / 100
            send(["type": "actions", "actions": actions()])
        case "pause":
            close(restoringFocus: true)
            engine.paused.toggle()
            HUD.show(title: engine.paused ? "Wallpaper paused" : "Wallpaper resumed",
                     detail: engine.paused ? "Your own wallpaper is back until you resume." : nil)
        case "history":
            close(restoringFocus: false)
            onOpenHistory?()
        case "home":
            close(restoringFocus: false)
            onOpenHome?(nil)
        default:
            break
        }
    }

    private func sendOpen() {
        let favorites = store.favoriteIDs
        let templates: [[String: Any]] = store.templates.map { t in
            ["id": t.id, "name": t.name, "description": t.description, "category": store.category(t.id),
             "builtin": t.builtin, "favorite": favorites.contains(t.id)]
        }
        var thumbs: [String: String] = [:]
        let version = engine.track?.id.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression) ?? "sample"
        for t in store.templates { thumbs[t.id] = thumbURL?(t.id) ?? "sw://app/thumb/\(t.id).jpg?v=\(version)" }
        let mouse = Self.screenUnderMouse()
        let screens: [[String: Any]] = NSScreen.screens.enumerated().map { i, s in
            ["id": displayID(s), "name": s.localizedName, "template": engine.templateID(for: s), "mouse": s == mouse, "main": i == 0]
        }
        let track = engine.statePayload(for: nil)["track"] as? [String: Any]
        send(["type": "open", "templates": templates, "recents": store.recentIDs, "screens": screens,
              "cover": track?["cover"] as? String ?? "sw://app/ui/sample-cover.jpg", "thumbs": thumbs, "actions": actions()])
    }

    private func actions() -> [[String: Any]] {
        let playing = engine.track != nil
        let hasLyrics = playing && !engine.lyricsSources.isEmpty
        let focus = isFocusOn?() ?? engine.focus
        let offset = engine.lyricsOffset
        let timing = hasLyrics ? (offset == 0 ? "This song · as published" : String(format: "This song · now %+.2f s", offset))
            : playing ? "No lyrics for this song" : "Nothing playing"
        return [
            ["id": "share", "icon": "share", "title": "Share Lyric Card", "sub": playing ? "The line being sung, as an image" : "Nothing playing",
             "kbd": "⌃⌥⌘L", "enabled": playing, "keywords": "share lyric card image story square copy picture",
             "desc": "Draws the main screen's template with the line being sung right now, saves it to Pictures and copies it."],
            ["id": "focus", "icon": "focus", "title": focus ? "Turn Focus Mode Off" : "Turn Focus Mode On",
             "sub": focus ? "Lyrics are hidden" : "Hide lyrics on every screen", "kbd": "⌃⌥⌘F", "enabled": true,
             "keywords": "focus mode hide lyrics private sharing", "desc": "Hides lyrics on every screen until you turn it off."],
            ["id": "earlier", "icon": "earlier", "title": "Lyrics 0.5 s Earlier", "sub": timing, "enabled": hasLyrics,
             "keywords": "lyrics timing offset earlier sooner sync ahead",
             "desc": "Shows this song's lines half a second sooner. Remembered for this song."],
            ["id": "later", "icon": "later", "title": "Lyrics 0.5 s Later", "sub": timing, "enabled": hasLyrics,
             "keywords": "lyrics timing offset later delay sync behind",
             "desc": "Shows this song's lines half a second later. Remembered for this song."],
            ["id": "pause", "icon": engine.paused ? "resume" : "pause", "title": engine.paused ? "Resume Wallpaper" : "Pause Wallpaper",
             "sub": engine.paused ? "Paused: your own wallpaper is showing" : "Give the desktop back for now", "enabled": true,
             "keywords": "pause resume stop off on start", "desc": engine.paused
                ? "Puts the song back on your desktop." : "Restores your own wallpaper until you resume."],
            ["id": "history", "icon": "history", "title": "Open History Wall", "sub": "Every song's wallpaper", "enabled": true,
             "keywords": "history wall gallery past saved", "desc": "The gallery of every wallpaper you've had, grouped by month."],
            ["id": "home", "icon": "home", "title": "Open Lirica", "sub": "Home", "enabled": true,
             "keywords": "home open settings customize window main",
             "desc": "The main window: templates and their settings, displays, history and lyrics."],
        ]
    }

    private func send(_ message: [String: Any]) {
        webView?.evaluateJavaScript("window.App && App.receive(\(jsonString(message)))")
    }
}

/// A borderless panel that can take the keyboard (borderless windows normally can't), so typing works.
final class SwitcherPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    // ⌘W from the app's menu
    override func performClose(_ sender: Any?) { onCancel?() }
}
