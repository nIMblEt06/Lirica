import AppKit
import WebKit

/// A live, animated copy of the template on one screen, drawn just above the real wallpaper and below the
/// desktop icons, on every Space. The real wallpaper underneath holds a still of the same song.
///
/// While the pointer is over one of the template's controls (`data-control`), the layer briefly takes mouse
/// clicks (`ignoresMouseEvents` off) so the control can be clicked; everywhere else clicks fall through to the
/// desktop as usual.
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
    /// The rects (in view coordinates) of the template's current `data-control` elements; sent by the runtime.
    private var controlRects: [CGRect] = []
    private var interactive = false

    /// Called when the controls on the page change, so the app can re-check its pointer watcher.
    var onControlsChanged: (() -> Void)?
    /// True while the layer is on screen.
    var isShown: Bool { visible }
    /// True while the page has controls the pointer can act on.
    var hasControls: Bool { !controlRects.isEmpty }

    init(screen: NSScreen, configuration: WKWebViewConfiguration) {
        frame = screen.frame
        webView = WallpaperWebView(frame: CGRect(origin: .zero, size: frame.size), configuration: configuration)
        window = WallpaperPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        rectBridge.layer = self
        configuration.userContentController.add(rectBridge, name: "swControls")
        window.setFrame(frame, display: false)
        // The wallpaper sits one level below desktopWindow and Finder's icons at desktopIconWindow.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
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
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        window.contentView = webView
        // when windows cover the whole desktop, stop every animation until it's visible again
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
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
        setControlRects([])  // the old page's controls are gone until the new one reports its own
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

    /// The runtime reports where the page's controls are; the app checks the pointer against these rects.
    func setControlRects(_ rects: [CGRect]) {
        guard rects != controlRects else { return }
        controlRects = rects
        onControlsChanged?()
    }

    /// True when the pointer (in screen coordinates) is over one of the controls.
    func isPointerOverControl(_ pointer: NSPoint) -> Bool {
        guard isShown, !controlRects.isEmpty, window.occlusionState.contains(.visible) else { return false }
        let p = CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y)
        return controlRects.contains { $0.insetBy(dx: -5, dy: -5).contains(p) }
    }

    /// Lets the layer take clicks (while the pointer is over a control) or pass them through to the desktop.
    func setInteractive(_ on: Bool) {
        guard interactive != on else { return }
        interactive = on
        window.ignoresMouseEvents = !on
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("SpotifyWallpaper: the live layer's web process ended; reloading it")
        loaded = false
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
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.6
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.visible == false { self?.window.orderOut(nil) }
            }
        })
    }

    func close() { window.close() }

}
