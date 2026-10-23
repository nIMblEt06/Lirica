import AppKit
import WebKit

/// "What's New": the changelog (CHANGELOG.md, bundled at build time), shown from the menu and once after each update.
@MainActor
final class WhatsNewWindowController: NSWindowController, WKScriptMessageHandler, NSWindowDelegate {
    private var recovery: ReloadOnCrash?
    private static let barHeight: CGFloat = 52

    init(engine: Engine) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "What's New"
        window.appearance = NSAppearance(named: .darkAqua)  // the page is always the frosted dark theme, like Home
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        let config = engine.makeWebConfiguration()
        config.userContentController.add(WeakScriptMessageHandler(self), name: "app")
        let container = NSView(frame: window.contentView!.bounds)
        let webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        let strip = DragStrip(frame: NSRect(x: 0, y: container.bounds.height - Self.barHeight, width: container.bounds.width, height: Self.barHeight))
        strip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(strip)
        window.contentView = container
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        recovery = ReloadOnCrash(webView)
        webView.load(URLRequest(url: URL(string: "sw://app/ui/changelog.html?v=\(version)")!))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.centerTrafficLights(inBarOfHeight: Self.barHeight)
    }

    func windowDidResize(_ notification: Notification) { window?.centerTrafficLights(inBarOfHeight: Self.barHeight) }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "open",
              let s = body["url"] as? String, let url = URL(string: s), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    /// True once per version: after an update (not on a fresh install).
    static func shouldShowAfterUpdate() -> Bool {
        let defaults = UserDefaults.standard
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let last = defaults.string(forKey: "lastSeenVersion")
        defaults.set(current, forKey: "lastSeenVersion")
        return last != nil && last != current
    }
}
