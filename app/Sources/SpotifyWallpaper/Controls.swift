import AppKit
import WebKit

/// The visual wallpaper window never accepts input or focus; native control hit windows are separate and tiny.
final class WallpaperPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The first click on an inactive window is normally swallowed to activate it; the desktop layer wants it, so
/// a control acts on the first click.
final class WallpaperWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A clear, nonactivating window over one playback control. Its level is the one used by Desktop Carpet: just
/// above Finder's desktop icons but below every application window. The full wallpaper can therefore stay at the
/// true wallpaper level while ordinary AppKit mouse events reach only these small exposed rectangles.
final class WallpaperControlPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect, onEvent: @escaping (String, NSPoint, Double) -> Void) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior = .none
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        contentView = WallpaperControlHitView(frame: CGRect(origin: .zero, size: frame.size), onEvent: onEvent)
    }
}

final class WallpaperControlHitView: NSView {
    private let onEvent: (String, NSPoint, Double) -> Void

    init(frame: CGRect, onEvent: @escaping (String, NSPoint, Double) -> Void) {
        self.onEvent = onEvent
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        onEvent("down", screenPoint(for: event), 0)
    }

    override func mouseDragged(with event: NSEvent) {
        onEvent("drag", screenPoint(for: event), 0)
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        onEvent("up", screenPoint(for: event), 0)
    }

    override func scrollWheel(with event: NSEvent) {
        let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        onEvent("wheel", screenPoint(for: event), -amount)
    }
}

struct WallpaperControlRegion: Equatable {
    let rect: CGRect
    let command: String
}

/// The live runtime reports its `data-control` rectangles so native hit windows can match them. A separate object
/// with a weak reference keeps WebKit's message controller from retaining the desktop layer.
@MainActor
final class ControlRectBridge: NSObject, WKScriptMessageHandler {
    weak var layer: DesktopLayer?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "swControls", let body = message.body as? [String: Any],
              let raw = body["regions"] as? [[String: Any]] else { return }
        let regions = raw.compactMap { r -> WallpaperControlRegion? in
            guard let x = (r["x"] as? NSNumber)?.doubleValue,
                  let y = (r["y"] as? NSNumber)?.doubleValue,
                  let width = (r["width"] as? NSNumber)?.doubleValue,
                  let height = (r["height"] as? NSNumber)?.doubleValue,
                  let command = r["command"] as? String else { return nil }
            return WallpaperControlRegion(rect: CGRect(x: x, y: y, width: width, height: height), command: command)
        }
        MainActor.assumeIsolated { layer?.setControlRegions(regions) }
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
            Trace.log("wallpaper control command: \(command)")
            engine?.performControl(command, value: (body["value"] as? NSNumber)?.doubleValue)
        }
    }
}
