import AppKit
import Foundation

/// Which applications and browser sites are allowed to become Lirica's music source.
///
/// The defaults are deliberately conservative: known music apps are allowed, unknown native apps are not, and a
/// browser is only useful after BrowserMediaResolver has tied its Now Playing metadata to a tab on an approved site.
/// Users can override either decision in Settings. Only application names and hostnames are remembered; tab titles,
/// full addresses and listening history never leave the in-memory browser snapshot.
enum MusicSourcePolicy {
    private struct Application {
        let bundle: String
        let name: String
        let kind: String
        let allowed: Bool
        let alwaysShow: Bool
    }

    private struct Site {
        let rule: String
        let name: String
        let allowed: Bool
        let alwaysShow: Bool
    }

    private static let applicationOverridesKey = "musicSource.applicationOverrides"
    private static let observedApplicationsKey = "musicSource.observedApplications"
    private static let siteOverridesKey = "musicSource.siteOverrides"
    private static let observedSitesKey = "musicSource.observedSites"
    private static let browserStatusesKey = "musicSource.browserStatuses"
    private static let lock = NSLock()
    static let chromiumGroup = "browser-group:chromium"

    private static let applications: [Application] = [
        .init(bundle: "com.spotify.client", name: "Spotify", kind: "direct", allowed: true, alwaysShow: true),
        .init(bundle: "com.apple.Music", name: "Apple Music", kind: "direct", allowed: true, alwaysShow: true),

        .init(bundle: "com.apple.Safari", name: "Safari", kind: "browser", allowed: true, alwaysShow: true),
        .init(bundle: "company.thebrowser.Browser", name: "Arc", kind: "browser", allowed: true, alwaysShow: false),
        .init(bundle: "com.google.Chrome", name: "Google Chrome", kind: "browser", allowed: true, alwaysShow: false),
        .init(bundle: "com.google.Chrome.canary", name: "Chrome Canary", kind: "browser", allowed: true, alwaysShow: false),
        .init(bundle: "org.chromium.Chromium", name: "Chromium", kind: "browser", allowed: true, alwaysShow: false),
        .init(bundle: "com.brave.Browser", name: "Brave Browser", kind: "browser", allowed: true, alwaysShow: false),
        .init(bundle: "com.microsoft.edgemac", name: "Microsoft Edge", kind: "browser", allowed: true, alwaysShow: false),
        .init(bundle: "com.vivaldi.Vivaldi", name: "Vivaldi", kind: "browser", allowed: true, alwaysShow: false),
        .init(bundle: "com.operasoftware.Opera", name: "Opera", kind: "browser", allowed: true, alwaysShow: false),
        .init(bundle: "org.mozilla.firefox", name: "Firefox", kind: "browser", allowed: true, alwaysShow: false),
        .init(bundle: "com.kagi.kagimacOS", name: "Orion", kind: "browser", allowed: true, alwaysShow: false),

        .init(bundle: "com.tidal.desktop", name: "TIDAL", kind: "music", allowed: true, alwaysShow: false),
        .init(bundle: "com.amazon.music", name: "Amazon Music", kind: "music", allowed: true, alwaysShow: false),
        .init(bundle: "com.deezer.deezer-desktop", name: "Deezer", kind: "music", allowed: true, alwaysShow: false),
        .init(bundle: "tv.plex.plexamp", name: "Plexamp", kind: "music", allowed: true, alwaysShow: false),
        .init(bundle: "com.coppertino.Vox", name: "VOX", kind: "music", allowed: true, alwaysShow: false),
        .init(bundle: "com.swinsian.Swinsian", name: "Swinsian", kind: "music", allowed: true, alwaysShow: false),
        .init(bundle: "com.roon.Roon", name: "Roon", kind: "music", allowed: true, alwaysShow: false),
        .init(bundle: "com.ciderapp.Cider", name: "Cider", kind: "music", allowed: true, alwaysShow: false),
    ]

    /// Rules match the exact host and its subdomains. Broad video hosts such as youtube.com are intentionally absent.
    private static let sites: [Site] = [
        .init(rule: "music.youtube.com", name: "YouTube Music", allowed: true, alwaysShow: true),
        .init(rule: "open.spotify.com", name: "Spotify Web", allowed: true, alwaysShow: true),
        .init(rule: "music.apple.com", name: "Apple Music Web", allowed: true, alwaysShow: true),
        .init(rule: "soundcloud.com", name: "SoundCloud", allowed: true, alwaysShow: true),
        .init(rule: "bandcamp.com", name: "Bandcamp", allowed: true, alwaysShow: true),
        .init(rule: "tidal.com", name: "TIDAL Web", allowed: true, alwaysShow: false),
        .init(rule: "deezer.com", name: "Deezer Web", allowed: true, alwaysShow: false),
        .init(rule: "play.qobuz.com", name: "Qobuz", allowed: true, alwaysShow: false),
        .init(rule: "pandora.com", name: "Pandora", allowed: true, alwaysShow: false),
        .init(rule: "mixcloud.com", name: "Mixcloud", allowed: true, alwaysShow: false),
        .init(rule: "audiomack.com", name: "Audiomack", allowed: true, alwaysShow: false),
    ]

    static func isBrowser(_ bundle: String) -> Bool {
        let id = bundle.lowercased()
        if isChromiumBrowser(bundle) { return true }
        return ["browser", "safari", "chrome", "chromium", "firefox", "edgemac", "brave", "opera", "vivaldi", "orion", "kagimacos"]
            .contains { id.contains($0) }
    }

    static func isChromiumBrowser(_ bundle: String) -> Bool {
        let id = bundle.lowercased()
        if id == chromiumGroup { return true }
        return ["thebrowser.browser", "chrome", "chromium", "brave", "edgemac", "vivaldi", "operasoftware.opera"]
            .contains { id.contains($0) }
    }

    static func applicationAllowed(bundle: String, name: String = "") -> Bool {
        let overrides = readBoolDictionary(applicationOverridesKey)
        if isChromiumBrowser(bundle), let value = overrides[chromiumGroup] { return value }
        if let value = overrides[bundle] { return value }
        if bundle == chromiumGroup { return true }
        if let known = applications.first(where: { $0.bundle == bundle }) { return known.allowed }
        if isBrowser(bundle) { return true }
        let haystack = (bundle + " " + name).lowercased()
        let musicNames = ["youtube music", "ytmusic", "spotify", "tidal", "deezer", "qobuz", "audirvana",
                          "plexamp", "soundcloud", "swinsian", "doppler", "roon", "cider", "amazon music"]
        return musicNames.contains { haystack.contains($0) }
    }

    static func setApplicationAllowed(_ allowed: Bool, bundle: String) {
        let key = isChromiumBrowser(bundle) ? chromiumGroup : bundle
        mutateBoolDictionary(applicationOverridesKey) { values in
            values[key] = allowed
            if key == chromiumGroup {
                for bundle in Array(values.keys) where bundle != chromiumGroup && isChromiumBrowser(bundle) {
                    values[bundle] = nil
                }
            }
        }
    }

    /// Returns true when the Settings snapshot changed.
    @discardableResult
    static func rememberApplication(bundle: String, name: String) -> Bool {
        guard !bundle.isEmpty else { return false }
        let knownName = applications.first { $0.bundle == bundle }?.name
        let cleanName = knownName ?? cleanedName(name, fallback: bundle)
        return mutateStringDictionary(observedApplicationsKey) { values in
            // Media clients should report an app name, but some implementations expose a changing page/player name.
            // The first useful value is enough to label an unknown bundle and avoids writing listening history here.
            guard values[bundle] == nil else { return false }
            values[bundle] = cleanName
            return true
        }
    }

    static func siteAllowed(host: String) -> Bool {
        let normalized = normalizeHost(host)
        let rule = siteRule(for: normalized)
        let overrides = readBoolDictionary(siteOverridesKey)
        if let value = overrides[rule] { return value }
        return sites.first(where: { $0.rule == rule })?.allowed ?? false
    }

    static func setSiteAllowed(_ allowed: Bool, rule: String) {
        mutateBoolDictionary(siteOverridesKey) { $0[normalizeHost(rule)] = allowed }
    }

    /// Remembers only the hostname, never the tab title or full URL. Returns true when Settings changed.
    @discardableResult
    static func rememberSite(_ host: String) -> Bool {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty else { return false }
        return mutateStringDictionary(observedSitesKey) { values in
            guard values[normalized] == nil else { return false }
            values[normalized] = normalized
            return true
        }
    }

    static func provider(forHost host: String) -> MusicProvider {
        switch siteRule(for: normalizeHost(host)) {
        case "music.youtube.com": return .youtubeMusic
        case "open.spotify.com": return .spotify
        case "music.apple.com": return .appleMusic
        default: return .other
        }
    }

    /// `ready`, `denied`, `unsupported` or `error`; persisted so Settings can explain why a browser is being skipped.
    @discardableResult
    static func setBrowserStatus(_ status: String, bundle: String) -> Bool {
        mutateStringDictionary(browserStatusesKey) { values in
            guard values[bundle] != status else { return false }
            values[bundle] = status
            return true
        }
    }

    // MARK: Settings snapshots

    @MainActor
    static func applicationSettings() -> [[String: Any]] {
        let observed = readStringDictionary(observedApplicationsKey)
        let overrides = readBoolDictionary(applicationOverridesKey)
        let statuses = readStringDictionary(browserStatusesKey)
        let knownByBundle = Dictionary(uniqueKeysWithValues: applications.map { ($0.bundle, $0) })
        let catalogOrder = Dictionary(uniqueKeysWithValues: applications.enumerated().map { ($0.element.bundle, $0.offset) })
        let bundles = Set(applications.compactMap { app in
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundle) != nil
            return app.alwaysShow || installed || observed[app.bundle] != nil || overrides[app.bundle] != nil ? app.bundle : nil
        }).union(observed.keys).union(overrides.keys.filter { $0 != chromiumGroup })

        let chromiumBundles = bundles.filter(isChromiumBrowser)
        var rows = bundles.filter { !isChromiumBrowser($0) }.map { bundle -> [String: Any] in
            let known = knownByBundle[bundle]
            let name = known?.name ?? observed[bundle] ?? bundle
            let kind = known?.kind ?? (isBrowser(bundle) ? "browser" : "other")
            return [
                "bundle": bundle,
                "name": name,
                "kind": kind,
                "enabled": applicationAllowed(bundle: bundle, name: name),
                "status": statuses[bundle] ?? "waiting",
            ]
        }

        if !chromiumBundles.isEmpty || overrides[chromiumGroup] != nil {
            let members = chromiumBundles.sorted { lhs, rhs in
                (catalogOrder[lhs] ?? Int.max) < (catalogOrder[rhs] ?? Int.max)
            }
            let names = members.map { knownByBundle[$0]?.name ?? observed[$0] ?? $0 }
            let statusOrder = ["denied", "error", "ready", "unsupported", "waiting"]
            let status = statusOrder.first { wanted in members.contains { statuses[$0] == wanted } } ?? "waiting"
            let statusNames = zip(members, names).compactMap { bundle, name in
                statuses[bundle] == status ? name : nil
            }
            let groupEnabled = overrides[chromiumGroup] ?? members.allSatisfy { overrides[$0] ?? true }
            rows.append([
                "bundle": chromiumGroup,
                "name": "Chromium browsers",
                "kind": "browser",
                "enabled": groupEnabled,
                "status": status,
                "members": names.joined(separator: ", "),
                "statusApps": statusNames.joined(separator: ", "),
            ])
        }

        return rows.sorted { lhs, rhs in
            let order = ["direct": 0, "browser": 1, "music": 2, "other": 3]
            let lk = lhs["kind"] as? String ?? "other", rk = rhs["kind"] as? String ?? "other"
            let lo = order[lk] ?? 3, ro = order[rk] ?? 3
            if lo != ro { return lo < ro }
            let lb = lhs["bundle"] as? String ?? "", rb = rhs["bundle"] as? String ?? ""
            let lr = lb == chromiumGroup ? 3 : catalogOrder[lb] ?? Int.max
            let rr = rb == chromiumGroup ? 3 : catalogOrder[rb] ?? Int.max
            if lr != rr { return lr < rr }
            return (lhs["name"] as? String ?? "").localizedCaseInsensitiveCompare(rhs["name"] as? String ?? "") == .orderedAscending
        }
    }

    @MainActor
    static func siteSettings() -> [[String: Any]] {
        let observed = readStringDictionary(observedSitesKey)
        let overrides = readBoolDictionary(siteOverridesKey)
        let knownByRule = Dictionary(uniqueKeysWithValues: sites.map { ($0.rule, $0) })
        let rules = Set(sites.compactMap { site in
            let wasSeen = observed.keys.contains { siteRule(for: $0) == site.rule }
            return site.alwaysShow || wasSeen || overrides[site.rule] != nil ? site.rule : nil
        }).union(observed.keys.map(siteRule(for:))).union(overrides.keys)

        return rules.map { rule -> [String: Any] in
            let known = knownByRule[rule]
            return [
                "host": rule,
                "name": known?.name ?? rule,
                "enabled": siteAllowed(host: rule),
                "recognized": known != nil,
            ]
        }.sorted { lhs, rhs in
            let lKnown = lhs["recognized"] as? Bool == true, rKnown = rhs["recognized"] as? Bool == true
            if lKnown != rKnown { return lKnown }
            return (lhs["name"] as? String ?? "").localizedCaseInsensitiveCompare(rhs["name"] as? String ?? "") == .orderedAscending
        }
    }

    // MARK: Helpers

    private static func siteRule(for host: String) -> String {
        sites.map(\.rule).sorted { $0.count > $1.count }
            .first { host == $0 || host.hasSuffix("." + $0) } ?? host
    }

    private static func normalizeHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value
    }

    private static func cleanedName(_ value: String, fallback: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty ? fallback : clean).prefix(80))
    }

    private static func readBoolDictionary(_ key: String) -> [String: Bool] {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.dictionary(forKey: key)?.compactMapValues { ($0 as? NSNumber)?.boolValue } ?? [:]
    }

    private static func readStringDictionary(_ key: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.dictionary(forKey: key)?.compactMapValues { $0 as? String } ?? [:]
    }

    private static func mutateBoolDictionary(_ key: String, _ change: (inout [String: Bool]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var values = UserDefaults.standard.dictionary(forKey: key)?.compactMapValues { ($0 as? NSNumber)?.boolValue } ?? [:]
        change(&values)
        UserDefaults.standard.set(values, forKey: key)
    }

    private static func mutateStringDictionary(_ key: String,
                                               _ change: (inout [String: String]) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var values = UserDefaults.standard.dictionary(forKey: key)?.compactMapValues { $0 as? String } ?? [:]
        guard change(&values) else { return false }
        UserDefaults.standard.set(values, forKey: key)
        return true
    }
}
