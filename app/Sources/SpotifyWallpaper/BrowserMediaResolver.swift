import AppKit
import Foundation

/// Best-effort, app-only browser source detection.
///
/// MediaRemote identifies the browser process but withholds the tab URL. Scriptable browsers do expose their tabs to
/// Apple Events, so the monitor compares each tab title with the Now Playing title/artist. A browser session is
/// accepted only when that produces one unambiguous hostname; callers still apply MusicSourcePolicy's site rule.
/// This never focuses a browser, executes page JavaScript or uses Accessibility.
final class BrowserMediaResolver {
    struct Tab: Equatable {
        let title: String
        let url: String
        let active: Bool
        let audibleWindow: Bool

        var host: String? {
            guard var host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
            while host.hasSuffix(".") { host.removeLast() }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
    }

    struct Result {
        let host: String?
        let settingsChanged: Bool
    }

    private struct Snapshot {
        let date: Date
        let tabs: [Tab]
    }

    private struct Failure {
        let retryAt: Date
    }

    private var scripts: [String: NSAppleScript] = [:]
    private var snapshots: [String: Snapshot] = [:]
    private var failures: [String: Failure] = [:]

    func resolve(bundle: String, track: Track, now: Date) -> Result {
        guard MusicSourcePolicy.isBrowser(bundle) else { return Result(host: nil, settingsChanged: false) }
        if let failure = failures[bundle], now < failure.retryAt {
            return Result(host: nil, settingsChanged: false)
        }

        let snapshot: Snapshot
        if let cached = snapshots[bundle], now.timeIntervalSince(cached.date) < (track.isPlaying ? 2 : 8) {
            snapshot = cached
        } else {
            let read = readTabs(bundle: bundle)
            var changed = read.settingsChanged
            guard let tabs = read.tabs else { return Result(host: nil, settingsChanged: changed) }
            snapshot = Snapshot(date: now, tabs: tabs)
            snapshots[bundle] = snapshot
            failures[bundle] = nil
            changed = MusicSourcePolicy.setBrowserStatus("ready", bundle: bundle) || changed
            return Result(host: Self.match(track: track, tabs: tabs)?.host, settingsChanged: changed)
        }
        return Result(host: Self.match(track: track, tabs: snapshot.tabs)?.host, settingsChanged: false)
    }

    /// Pure matching logic kept internal so it can be exercised without sending an Apple Event.
    static func match(track: Track, tabs: [Tab]) -> Tab? {
        let usable = tabs.filter { $0.host != nil }
        guard !usable.isEmpty else { return nil }
        if usable.count == 1 { return usable[0] }

        let title = normalize(track.title)
        let artist = normalize(track.artist)
        guard title.count >= 2 else { return nil }
        let scored = usable.compactMap { tab -> (tab: Tab, score: Int)? in
            let candidate = normalize(tab.title)
            guard !candidate.isEmpty else { return nil }
            var score = 0
            if candidate == title { score = 100 }
            else if containsPhrase(candidate, title) { score = 72 }
            else if title.count >= 7, containsPhrase(title, candidate) { score = 52 }
            else {
                let words = Set(title.split(separator: " ").map(String.init).filter { $0.count > 1 })
                let candidateWords = Set(candidate.split(separator: " ").map(String.init))
                if words.count >= 2, words.isSubset(of: candidateWords) { score = 48 }
            }
            guard score > 0 else { return nil }
            if artist.count >= 2, containsPhrase(candidate, artist) { score += 18 }
            if tab.audibleWindow { score += 4 }
            if tab.active { score += 1 }
            return (tab, score)
        }.sorted { $0.score > $1.score }

        guard let best = scored.first, best.score >= 48 else { return nil }
        if let second = scored.dropFirst().first,
           second.tab.host != best.tab.host,
           best.score - second.score <= 5 { return nil }
        return best.tab
    }

    private func readTabs(bundle: String) -> (tabs: [Tab]?, settingsChanged: Bool) {
        guard Self.isScriptable(bundle) else {
            return (nil, MusicSourcePolicy.setBrowserStatus("unsupported", bundle: bundle))
        }
        // Never let an Apple Event launch a browser just because MediaRemote retained a stale session.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return ([], false) }
        let script: NSAppleScript
        if let cached = scripts[bundle] {
            script = cached
        } else {
            guard let new = NSAppleScript(source: Self.scriptSource(bundle: bundle)) else {
                return (nil, MusicSourcePolicy.setBrowserStatus("unsupported", bundle: bundle))
            }
            var compileError: NSDictionary?
            guard new.compileAndReturnError(&compileError) else {
                return (nil, MusicSourcePolicy.setBrowserStatus("unsupported", bundle: bundle))
            }
            scripts[bundle] = new
            script = new
        }

        var error: NSDictionary?
        let value = script.executeAndReturnError(&error).stringValue
        guard let value else {
            let number = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let status = number == -1743 ? "denied" : "error"
            let delay: TimeInterval = number == -1743 ? 60 : 15
            failures[bundle] = Failure(retryAt: Date().addingTimeInterval(delay))
            return (nil, MusicSourcePolicy.setBrowserStatus(status, bundle: bundle))
        }
        return (Self.parse(value), false)
    }

    private static func parse(_ value: String) -> [Tab] {
        value.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { row in
            let fields = row.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { return nil }
            let windowName = fields[3]
            return Tab(title: fields[0], url: fields[1], active: fields[2] == "true",
                       audibleWindow: windowName.contains("🔊") || windowName.localizedCaseInsensitiveContains("audio playing"))
        }
    }

    private static func scriptSource(bundle: String) -> String {
        let safeBundle = bundle.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        if bundle.lowercased().contains("safari") {
            return """
            set fieldSeparator to ASCII character 31
            set recordSeparator to ASCII character 30
            set rows to ""
            if application id "\(safeBundle)" is not running then return ""
            tell application id "\(safeBundle)"
              repeat with w in windows
                set currentIndex to 0
                set windowTitle to ""
                try
                  set currentIndex to index of current tab of w
                end try
                try
                  set windowTitle to name of w as text
                end try
                repeat with t in tabs of w
                  try
                    set isActive to ((index of t) is currentIndex)
                    set rows to rows & (name of t as text) & fieldSeparator & (URL of t as text) & fieldSeparator & (isActive as text) & fieldSeparator & windowTitle & recordSeparator
                  end try
                end repeat
              end repeat
            end tell
            return rows
            """
        }
        return """
        set fieldSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        set rows to ""
        if application id "\(safeBundle)" is not running then return ""
        tell application id "\(safeBundle)"
          repeat with w in windows
            set activeTabID to ""
            set windowTitle to ""
            try
              set activeTabID to id of active tab of w as text
            end try
            try
              set windowTitle to name of w as text
            end try
            repeat with t in tabs of w
              try
                set tabID to id of t as text
                set isActive to (tabID is activeTabID)
                set rows to rows & (title of t as text) & fieldSeparator & (URL of t as text) & fieldSeparator & (isActive as text) & fieldSeparator & windowTitle & recordSeparator
              end try
            end repeat
          end repeat
        end tell
        return rows
        """
    }

    private static func isScriptable(_ bundle: String) -> Bool {
        let id = bundle.lowercased()
        if id.contains("firefox") { return false }
        return ["safari", "chrome", "chromium", "browser", "brave", "edgemac", "vivaldi", "opera", "orion", "kagimacos"]
            .contains { id.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func containsPhrase(_ haystack: String, _ needle: String) -> Bool {
        haystack == needle || haystack.hasPrefix(needle + " ") || haystack.hasSuffix(" " + needle) || haystack.contains(" " + needle + " ")
    }
}
