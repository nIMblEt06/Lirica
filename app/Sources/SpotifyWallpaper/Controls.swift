import AppKit
import WebKit

/// The live layer's window. A nonactivating panel, so clicking a control on the wallpaper never activates the
/// app or steals focus from whatever you're using; `becomesKeyOnlyIfNeeded` keeps it from taking the keyboard.
final class WallpaperPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The first click on an inactive window is normally swallowed to activate it; the desktop layer wants it, so
/// a control acts on the first click.
final class WallpaperWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The live layer's runtime reports where its `data-control` elements are, so the app knows where the pointer
/// may take clicks away from the desktop. A separate object with a weak reference, so the page's controller
/// never keeps the layer alive.
@MainActor
final class ControlRectBridge: NSObject, WKScriptMessageHandler {
    weak var layer: DesktopLayer?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "swControls", let body = message.body as? [String: Any],
              let raw = body["rects"] as? [[NSNumber]] else { return }
        let rects = raw.compactMap { r -> CGRect? in
            guard r.count == 4 else { return nil }
            return CGRect(x: r[0].doubleValue, y: r[1].doubleValue, width: r[2].doubleValue, height: r[3].doubleValue)
        }
        MainActor.assumeIsolated { layer?.setControlRects(rects) }
    }
}

/// Commands from template controls (`data-control`, `Wallpaper.control`) arrive here and go to Spotify.
@MainActor
final class ControlBridge: NSObject, WKScriptMessageHandler {
    private weak var engine: Engine?

    init(engine: Engine) { self.engine = engine }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "swCommand", let body = message.body as? [String: Any],
              let command = body["command"] as? String else { return }
        MainActor.assumeIsolated {
            engine?.performControl(command, value: (body["value"] as? NSNumber)?.doubleValue)
        }
    }
}
