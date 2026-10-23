import WebKit

/// `WKUserContentController` retains its script message handlers **strongly**. Registering a window
/// controller directly with `add(self, name:)` creates this cycle:
///
///     controller → webView → configuration → userContentController → controller
///
/// so `close()` and dropping the last reference can never free the controller. Its `WKWebView` and
/// its web content process then live forever — one leaked process (~40–130 MB) per window that is
/// recreated, which is unbounded for the Template Builder (`AppDelegate.openBuilder`).
///
/// The controller retains this proxy; the proxy holds the real handler weakly, so the cycle is gone.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // WebKit delivers script messages on the main thread.
        MainActor.assumeIsolated {
            target?.userContentController(userContentController, didReceive: message)
        }
    }
}
