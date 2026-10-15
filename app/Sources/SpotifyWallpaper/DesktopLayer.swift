import AppKit
import WebKit

/// A live, animated copy of the template on one screen, drawn just above the real wallpaper and below the
/// desktop icons, on every Space. The real wallpaper underneath holds a still of the same song.
///
/// Each template control (`data-control`) gets a separate clear hit window above Finder's icons but below all app
/// windows. The full-screen layer itself always ignores input and remains at the genuine wallpaper level.
@MainActor
final class DesktopLayer: NSObject, WKNavigationDelegate {
    let frame: CGRect
    private let window: WallpaperPanel
    private let webView: WallpaperWebView
    private let rectBridge = ControlRectBridge()
    private var url: URL?
    private var loaded = false
    private var full: String?
    private var clock: String?
    private var visible = false
    /// The template's current `data-control` elements in view coordinates; sent by the runtime.
    private var controlRegions: [WallpaperControlRegion] = []
    private var controlPanels: [WallpaperControlPanel] = []
    private var controlsEnabled = false
    private var controlGestureActive = false
    private var controlPanelsNeedRebuild = false

    /// True while the layer is on screen.
    var isShown: Bool { visible }

    init(screen: NSScreen, configuration: WKWebViewConfiguration) {
        frame = screen.frame
        webView = WallpaperWebView(frame: CGRect(origin: .zero, size: frame.size), configuration: configuration)
        window = WallpaperPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        rectBridge.layer = self
        configuration.userContentController.add(rectBridge, name: "swControls")
        window.setFrame(frame, display: false)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .black
        window.alphaValue = 0
        // the panel mustn't hide itself when the app isn't active; clicks mustn't activate the app either
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        window.becomesKeyOnlyIfNeeded = true
        // `isFloatingPanel = false` resets an NSPanel to `.normal`; assign this afterwards so the full-screen
        // layer really stays behind applications. Controls use separate desktop-icon-level hit windows.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        window.contentView = webView
        // when windows cover the whole desktop, stop every animation until it's visible again
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        }
    }

    /// A Space change can leave the page paused until macOS reports occlusion again. Re-check while the transition
    /// settles, but never reorder the window: ordering a full-screen all-Spaces panel can cover the destination app.
    func spaceChanged() {
        guard visible else { return }
        occlusionChanged()
        for delay in [0.15, 0.5, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.visible else { return }
                    self.occlusionChanged()
                }
            }
        }
    }

    private func occlusionChanged() {
        guard loaded, visible else { return }
        let hidden = !window.occlusionState.contains(.visible)
        webView.evaluateJavaScript("window.__sw && __sw.pause(\(hidden))")
    }

    func load(_ newURL: URL) {
        guard newURL != url else { return }
        url = newURL
        loaded = false
        setControlRegions([])  // the old page's controls are gone until the new one reports its own
        webView.load(URLRequest(url: newURL))
    }

    /// Everything the template needs; sent when the track, template or settings change.
    func sendState(_ json: String) {
        full = json
        if loaded { webView.evaluateJavaScript("window.__sw && __sw.live(\(json))") }
    }

    /// Just the playback position, sent on every Spotify check to keep the template's clock in sync.
    func sendClock(_ json: String) {
        clock = json
        if loaded { webView.evaluateJavaScript("window.__sw && __sw.clock(\(json))") }
    }

    /// A beat or loudness update (see AudioAnalyzer); dropped while the layer can't be seen.
    func sendBeat(_ json: String) {
        guard loaded, visible, window.occlusionState.contains(.visible) else { return }
        webView.evaluateJavaScript("window.__sw && __sw.beat && __sw.beat(\(json))")
    }

    // MARK: controls (data-control in templates)

    /// The runtime reports where the page's controls are; rebuild their small native hit windows.
    func setControlRegions(_ regions: [WallpaperControlRegion]) {
        guard regions != controlRegions else { return }
        controlRegions = regions
        Trace.log("wallpaper controls: \(regions.count) hit regions")
        rebuildControlPanels()
    }

    func setControlInteractionEnabled(_ enabled: Bool) {
        guard controlsEnabled != enabled else { return }
        controlsEnabled = enabled
        rebuildControlPanels()
    }

    private func rebuildControlPanels() {
        guard !controlGestureActive else {
            controlPanelsNeedRebuild = true
            return
        }
        controlPanels.forEach { $0.close() }
        controlPanels.removeAll()
        controlPanelsNeedRebuild = false
        guard controlsEnabled, loaded, visible else { return }

        for region in controlRegions {
            let bounds = CGRect(origin: .zero, size: frame.size)
            let hit = region.rect.insetBy(dx: -5, dy: -5).intersection(bounds)
            guard !hit.isNull, !hit.isEmpty else { continue }
            let panelFrame = CGRect(
                x: frame.minX + hit.minX,
                y: frame.maxY - hit.maxY,
                width: hit.width,
                height: hit.height
            )
            let panel = WallpaperControlPanel(frame: panelFrame) { [weak self] type, point, deltaY in
                guard let self else { return }
                if type == "down" {
                    self.controlGestureActive = true
                    Trace.log("wallpaper control: mouse down from desktop hit window")
                }
                self.sendControlEvent(type, at: point, deltaY: deltaY)
                if type == "up" {
                    self.controlGestureActive = false
                    if self.controlPanelsNeedRebuild {
                        DispatchQueue.main.async { [weak self] in self?.rebuildControlPanels() }
                    }
                }
            }
            panel.orderFrontRegardless()
            controlPanels.append(panel)
        }
        if !controlPanels.isEmpty {
            Trace.log("wallpaper controls: \(controlPanels.count) desktop hit windows active")
        }
    }

    /// Sends a native hit-window event into the page's normal control handlers.
    func sendControlEvent(_ type: String, at pointer: NSPoint, deltaY: Double = 0) {
        guard loaded, visible else { return }
        let x = pointer.x - frame.minX, y = frame.maxY - pointer.y
        let event = jsonString(["type": type, "x": x, "y": y, "deltaY": deltaY])
        webView.evaluateJavaScript("window.__sw && __sw.controlEvent(\(event))")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("SpotifyWallpaper: the live layer's web process ended; reloading it")
        loaded = false
        setControlRegions([])
        webView.reload()  // didFinish then resends the state and clock
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let full { webView.evaluateJavaScript("window.__sw && __sw.live(\(full))") }
        if let clock { webView.evaluateJavaScript("window.__sw && __sw.clock(\(clock))") }
    }

    func show() {
        guard !visible, loaded, full != nil else { return }
        visible = true
        Trace.log("wallpaper shown: \(frame)")
        window.orderFrontRegardless()
        rebuildControlPanels()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        controlGestureActive = false
        rebuildControlPanels()
        Trace.log("wallpaper hidden: \(frame)")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.6
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.visible == false { self?.window.orderOut(nil) }
            }
        })
    }

    func close() {
        controlGestureActive = false
        controlPanels.forEach { $0.close() }
        controlPanels.removeAll()
        window.close()
    }

}
