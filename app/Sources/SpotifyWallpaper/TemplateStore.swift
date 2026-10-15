import ColorSync
import CoreGraphics
import Foundation

struct WallpaperTemplate {
    let id: String  // folder name
    let dir: URL
    let manifest: [String: Any]
    let builtin: Bool

    var name: String { manifest["name"] as? String ?? id }
    var description: String { manifest["description"] as? String ?? "" }
    var params: [[String: Any]] { manifest["params"] as? [[String: Any]] ?? [] }
    var url: URL { URL(string: "sw://app/template/\(id)/index.html")! }

    /// Made with the Template Builder (has a design.json).
    var isBuilder: Bool { manifest["builder"] as? Bool ?? false }

    var summary: [String: Any] {
        ["id": id, "name": name, "description": description, "builtin": builtin, "builder": isBuilder, "params": params,
         "category": TemplateStore.categoryName(self)]
    }
}

/// Built-in templates ship in the app bundle; user templates live in
/// ~/Library/Application Support/Spotify Wallpaper/Templates and override built-ins with the same folder name.
@MainActor
final class TemplateStore {
    private(set) var templates: [WallpaperTemplate] = []
    private let paths: Paths
    private let defaults: UserDefaults
    private static let builtinOrder = ["card", "poster", "minimal", "glow", "vinyl", "typewriter", "lockscreen", "visualizer", "brushwork", "painted-cover", "painted-cover-wide", "cassette", "liner-notes", "weather", "departure-board", "riso", "swiss-grid", "hardware-panel", "film-strip", "albers", "breathing-type", "receipt", "one-bit", "teletext", "text-mode", "contour-map", "classic", "stained-glass", "remote", "jukebox", "island"]

    /// Fires after any `setActive` (all screens or one), i.e. whenever what a screen shows may have changed.
    var onActiveChanged: (() -> Void)?
    /// Posted alongside `onActiveChanged`, for observers that shouldn't take the single closure (the Engine).
    static let activeChangedNotification = Notification.Name("TemplateStore.activeChanged")

    /// Maps a display to a string that survives reconnects and reboots (its UUID). Replaceable for tests.
    var displayUUID: (CGDirectDisplayID) -> String? = TemplateStore.uuidString(for:)
    /// The displays that are connected right now. Replaceable for tests.
    var onlineDisplays: () -> [CGDirectDisplayID] = TemplateStore.onlineDisplayIDs

    init(paths: Paths, defaults: UserDefaults = .standard) {
        self.paths = paths
        self.defaults = defaults
        installGuide()
        reload()
    }

    func reload() {
        var byID: [String: WallpaperTemplate] = [:]
        for (dir, builtin) in [(paths.builtinTemplates, true), (paths.userTemplates, false)] {
            let subs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for sub in subs {
                guard let data = try? Data(contentsOf: sub.appendingPathComponent("manifest.json")),
                      let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                byID[sub.lastPathComponent] = WallpaperTemplate(id: sub.lastPathComponent, dir: sub, manifest: manifest, builtin: builtin)
            }
        }
        templates = byID.values.sorted { a, b in
            let ia = Self.builtinOrder.firstIndex(of: a.id) ?? Int.max, ib = Self.builtinOrder.firstIndex(of: b.id) ?? Int.max
            return ia != ib ? ia < ib : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func template(_ id: String) -> WallpaperTemplate? { templates.first { $0.id == id } }

    /// The template every screen shows unless it has its own (see `displayOverrides`).
    /// Setting it means "use this as the wallpaper": same as `setActive(id, display: nil)`.
    var activeID: String {
        get {
            let saved = defaults.string(forKey: "activeTemplate") ?? "card"
            return template(saved) != nil ? saved : (templates.first?.id ?? "card")
        }
        set { setActive(newValue, display: nil) }
    }

    var active: WallpaperTemplate? { template(activeID) }

    // MARK: per-display templates, recents, favourites

    private static let overridesKey = "displayTemplates"  // [display UUID: template id]
    private static let recentsKey = "recentTemplates"
    private static let favoritesKey = "favoriteTemplates"
    static let maxRecents = 12

    /// What `display` shows: its own template if it has one (and it still exists), else `activeID`.
    func activeID(for display: CGDirectDisplayID) -> String {
        displayOverrides[display] ?? activeID
    }

    /// `display == nil`: every screen shows `id` and per-screen choices are cleared.
    /// Otherwise only that screen changes; picking the default for it just drops its override.
    func setActive(_ id: String, display: CGDirectDisplayID?) {
        var saved = savedOverrides
        if let display {
            guard let uuid = displayUUID(display) else { return }
            saved[uuid] = id == activeID ? nil : id
        } else {
            defaults.set(id, forKey: "activeTemplate")
            saved = [:]
        }
        defaults.set(saved, forKey: Self.overridesKey)
        noteRecent(id)
        onActiveChanged?()
        NotificationCenter.default.post(name: Self.activeChangedNotification, object: self)
    }

    /// Screens (connected now) that show something other than the default, with templates that still exist.
    var displayOverrides: [CGDirectDisplayID: String] {
        let saved = savedOverrides
        guard !saved.isEmpty else { return [:] }
        var out: [CGDirectDisplayID: String] = [:]
        for display in onlineDisplays() {
            if let uuid = displayUUID(display), let id = saved[uuid], template(id) != nil { out[display] = id }
        }
        return out
    }

    private var savedOverrides: [String: String] {
        defaults.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
    }

    /// Most recently applied first; templates that were deleted are skipped.
    var recentIDs: [String] {
        (defaults.stringArray(forKey: Self.recentsKey) ?? []).filter { template($0) != nil }
    }

    private func noteRecent(_ id: String) {
        var list = (defaults.stringArray(forKey: Self.recentsKey) ?? []).filter { $0 != id }
        list.insert(id, at: 0)
        defaults.set(Array(list.prefix(Self.maxRecents)), forKey: Self.recentsKey)
    }

    var favoriteIDs: Set<String> {
        Set((defaults.stringArray(forKey: Self.favoritesKey) ?? []).filter { template($0) != nil })
    }

    func setFavorite(_ id: String, _ on: Bool) {
        var list = (defaults.stringArray(forKey: Self.favoritesKey) ?? []).filter { $0 != id }
        if on { list.append(id) }
        defaults.set(list, forKey: Self.favoritesKey)
    }

    /// Display names for the manifest's optional `"category"`, in gallery order (plus "Yours").
    nonisolated static let categoryNames = ["lyrics": "Lyrics", "painting": "Painting", "print": "Print & paper", "objects": "Objects", "calm": "Calm"]
    nonisolated static let categoryOrder = ["Lyrics", "Painting", "Print & paper", "Objects", "Calm", "Yours"]

    /// The manifest's category, else "Yours" for user templates and "Lyrics" for built-ins.
    func category(_ id: String) -> String {
        guard let t = template(id) else { return "Yours" }
        return Self.categoryName(t)
    }

    nonisolated static func categoryName(_ t: WallpaperTemplate) -> String {
        if let raw = t.manifest["category"] as? String, let name = categoryNames[raw.lowercased()] { return name }
        return t.builtin ? "Lyrics" : "Yours"
    }

    nonisolated static func uuidString(for display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    nonisolated static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    // MARK: parameter values

    func values(_ id: String) -> [String: Any] {
        var out = defaultValues(id)
        for (k, v) in saved(id) { out[k] = v }
        return out
    }

    func defaultValues(_ id: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for p in template(id)?.params ?? [] {
            if let key = p["key"] as? String { out[key] = p["default"] }
        }
        return out
    }

    func setValue(_ id: String, key: String, value: Any) {
        var s = saved(id)
        s[key] = value
        defaults.set(s, forKey: "params." + id)
    }

    func reset(_ id: String) { defaults.removeObject(forKey: "params." + id) }

    private func saved(_ id: String) -> [String: Any] {
        defaults.dictionary(forKey: "params." + id) ?? [:]
    }

    // MARK: editing

    /// Copies a template into the user folder so its code can be edited. Returns the new id.
    func duplicate(_ id: String) -> String? {
        guard let src = template(id) else { return nil }
        let fm = FileManager.default
        var newID = id + "-custom", n = 2
        while fm.fileExists(atPath: paths.userTemplates.appendingPathComponent(newID).path) {
            newID = "\(id)-custom-\(n)"; n += 1
        }
        let dest = paths.userTemplates.appendingPathComponent(newID)
        do { try fm.copyItem(at: src.dir, to: dest) } catch { return nil }
        var manifest = src.manifest
        manifest["name"] = src.name + " (Custom)"
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dest.appendingPathComponent("manifest.json"))
        }
        defaults.set(saved(id), forKey: "params." + newID)
        reload()
        return newID
    }

    // MARK: Template Builder

    func design(_ id: String) -> Any? {
        guard let t = template(id), let data = try? Data(contentsOf: t.dir.appendingPathComponent("design.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Saves a Builder design, creating the template folder the first time. Returns the template id.
    func saveDesign(id: String?, name: String, design: Any) -> String? {
        let fm = FileManager.default
        var folderID = id.flatMap { template($0)?.builtin == false ? $0 : nil }
        if folderID == nil {
            var slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if slug.isEmpty { slug = "my-template" }
            var candidate = slug, n = 2
            while template(candidate) != nil || fm.fileExists(atPath: paths.userTemplates.appendingPathComponent(candidate).path) {
                candidate = "\(slug)-\(n)"; n += 1
            }
            folderID = candidate
        }
        guard let folderID else { return nil }
        let dir = paths.userTemplates.appendingPathComponent(folderID)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["name": name, "description": "Made with the Template Builder.", "author": NSFullUserName(),
                                           "builder": true, "params": []]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent("manifest.json"))
            try JSONSerialization.data(withJSONObject: design, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent("design.json"))
            let page = dir.appendingPathComponent("index.html")
            try? fm.removeItem(at: page)
            try fm.copyItem(at: paths.web.appendingPathComponent("runtime/builder-template.html"), to: page)
        } catch {
            NSLog("SpotifyWallpaper: couldn't save design: \(error)")
            return nil
        }
        reload()
        return folderID
    }

    /// A plain HTML/CSS template (e.g. a Builder design exported to code). Returns the template id.
    func createCodeTemplate(name: String, html: String) -> String? {
        let fm = FileManager.default
        var slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "my-template-code" }
        var id = slug, n = 2
        while template(id) != nil || fm.fileExists(atPath: paths.userTemplates.appendingPathComponent(id).path) {
            id = "\(slug)-\(n)"; n += 1
        }
        let dir = paths.userTemplates.appendingPathComponent(id)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["name": name, "description": "Exported from the Template Builder. Edit index.html freely.",
                                           "author": NSFullUserName(), "params": []]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent("manifest.json"))
            try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        reload()
        return id
    }

    /// Latest modification time across user templates, for live reload while editing code.
    func userTemplatesStamp() -> Date {
        var latest = Date.distantPast
        for t in templates where !t.builtin {
            let files = FileManager.default.enumerator(at: t.dir, includingPropertiesForKeys: [.contentModificationDateKey])
            while let f = files?.nextObject() as? URL {
                if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d > latest { latest = d }
            }
        }
        return latest
    }

    private func installGuide() {
        let src = paths.web.appendingPathComponent("TEMPLATE_GUIDE.md")
        let dest = paths.userTemplates.appendingPathComponent("TEMPLATE_GUIDE.md")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
    }
}
