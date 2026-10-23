import AppKit
import WebKit

/// The Template Builder: a no-code editor for templates. Designs are saved as normal template folders
/// (manifest.json + design.json + a stock index.html that renders the design).
@MainActor
final class BuilderWindowController: NSWindowController, WKScriptMessageHandler, WKUIDelegate, NSWindowDelegate {
    private let engine: Engine
    private let store: TemplateStore
    private var webView: WKWebView!
    private var recovery: ReloadOnCrash?
    private var strip: DragStrip!
    private static let barHeight: CGFloat = 52
    private(set) var templateID: String?
    var onSaved: (() -> Void)?

    init(engine: Engine, store: TemplateStore, templateID: String?) {
        self.engine = engine
        self.store = store
        self.templateID = templateID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Template Builder"
        window.appearance = NSAppearance(named: .darkAqua)  // the page is always the frosted dark theme, like Home
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 1100, height: 680)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        let config = engine.makeWebConfiguration()
        // see HomeWindow: a weak proxy, or this controller would outlive every `close()`
        config.userContentController.add(WeakScriptMessageHandler(self), name: "app")
        let container = NSView(frame: window.contentView!.bounds)
        webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.uiDelegate = self
        container.addSubview(webView)
        // the page draws the title bar itself; this strip makes its empty parts drag the window
        strip = DragStrip(frame: NSRect(x: 0, y: container.bounds.height - Self.barHeight,
                                        width: container.bounds.width, height: Self.barHeight))
        strip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(strip)
        window.contentView = container
        recovery = ReloadOnCrash(webView)
        webView.load(URLRequest(url: URL(string: "sw://app/ui/builder.html")!))
    }

    func windowDidResize(_ notification: Notification) { window?.centerTrafficLights(inBarOfHeight: Self.barHeight) }
    func windowDidExitFullScreen(_ notification: Notification) { window?.centerTrafficLights(inBarOfHeight: Self.barHeight) }

    /// <input type="file"> in the page (adding images).
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.message = "Choose an image to add to your template"
        panel.beginSheetModal(for: window!) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.centerTrafficLights(inBarOfHeight: Self.barHeight)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            var msg: [String: Any] = ["type": "init", "state": engine.statePayload(), "screens": screens()]
            if let id = templateID, let t = store.template(id) {
                msg["id"] = id
                msg["name"] = t.name
                msg["design"] = store.design(id) ?? NSNull()
            }
            send(msg)
        case "save":
            let name = (body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "My Template"
            guard let design = body["design"], let id = store.saveDesign(id: templateID, name: name, design: design) else {
                send(["type": "saveFailed"])
                return
            }
            templateID = id
            if body["activate"] as? Bool == true { store.activeID = id }
            engine.invalidate()
            onSaved?()
            send(["type": "saved", "id": id, "active": store.activeID == id])
        case "titlebarHoles":
            let rects = body["rects"] as? [[String: Double]] ?? []
            strip.holes = rects.map { NSRect(x: $0["x"] ?? 0, y: $0["y"] ?? 0, width: $0["w"] ?? 0, height: $0["h"] ?? 0) }
        case "exportCode":
            let name = (body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "My Template"
            guard let html = body["html"] as? String, let id = store.createCodeTemplate(name: name + " (Code)", html: html),
                  let t = store.template(id) else {
                send(["type": "toast", "text": "Couldn't create the code copy"])
                return
            }
            onSaved?()
            let page = t.dir.appendingPathComponent("index.html")
            let editor = CodeEditor.open(page)
            send(["type": "toast", "text": "Created “\(t.name)”" + (editor.map { " and opened it in \($0)" } ?? "")
                  + ". It reloads on your desktop every time you save."])
        case "reveal":
            if let id = templateID, let t = store.template(id) {
                NSWorkspace.shared.activateFileViewerSelecting([t.dir.appendingPathComponent("design.json")])
            }
        default:
            break
        }
    }

    /// The real screens, so the canvas can preview each one's shape.
    private func screens() -> [[String: Any]] {
        NSScreen.screens.map { s in
            ["name": s.localizedName, "width": s.frame.width, "height": s.frame.height]
        }
    }

    func pushState() {
        guard window?.isVisible == true else { return }
        send(["type": "state", "state": engine.statePayload()])
    }

    func pushClock(_ json: String) {
        guard window?.isVisible == true else { return }
        webView.evaluateJavaScript("window.App && App.receive({type: 'clock', clock: \(json)})")
    }

    func evaluate(_ js: String) async -> Any? {
        if js.contains("new Promise") {
            return try? await webView.callAsyncJavaScript("return await " + js, arguments: [:], in: nil, contentWorld: .page)
        }
        return try? await webView.evaluateJavaScript(js)
    }

    func snapshot() async -> NSImage? {
        try? await webView.takeSnapshot(configuration: nil)
    }

    private func send(_ message: [String: Any]) {
        webView.evaluateJavaScript("window.App && App.receive(\(jsonString(message)))")
    }
}
