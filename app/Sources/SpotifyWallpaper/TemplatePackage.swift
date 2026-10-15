import AppKit
import UniformTypeIdentifiers

/// `.swtemplate` files: a template folder zipped by ditto (no AppleDouble files), shared and installed whole.
///   export:  <id>/manifest.json, <id>/index.html, … (`ditto -c -k --keepParent`, no forks/xattrs)
///   import:  checked before anything is unpacked (size, entry names, symlinks), then unpacked into a temp
///            folder, checked again, and moved into the user templates folder under a free id.
enum TemplatePackage {
    static let fileExtension = "swtemplate"
    static let typeIdentifier = "com.shashvat.spotifywallpaper.template"
    static let maxBytes = 25 * 1024 * 1024       // the .swtemplate itself
    static let maxUnpackedBytes = 100 * 1024 * 1024
    static let maxEntries = 2000

    static var contentType: UTType {
        UTType(typeIdentifier) ?? UTType(filenameExtension: fileExtension, conformingTo: .data) ?? .data
    }

    enum Failure: LocalizedError {
        case tooBig, notZip, unsafe(String), missing(String), badManifest, tool(String), download(String)
        var errorDescription: String? {
            switch self {
            case .tooBig: return "The template is larger than \(maxBytes / 1024 / 1024) MB."
            case .notZip: return "This isn't a Lirica template file."
            case .unsafe(let s): return "The template contains an unsafe file (\(s))."
            case .missing(let s): return "The template has no \(s)."
            case .badManifest: return "The template's manifest.json can't be read."
            case .tool(let s): return "Couldn't pack or unpack the template: \(s)"
            case .download(let s): return "Couldn't download the template: \(s)"
            }
        }
    }

    // MARK: export

    /// Zips `dir` to `dest`, leaving out Finder litter. Blocking: call off the main thread.
    static func export(_ dir: URL, to dest: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("swtemplate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let copy = work.appendingPathComponent(dir.lastPathComponent)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.copyItem(at: dir, to: copy)
        if let files = fm.enumerator(at: copy, includingPropertiesForKeys: nil) {
            for case let f as URL in files where f.lastPathComponent == ".DS_Store" || f.lastPathComponent.hasPrefix("._") {
                try? fm.removeItem(at: f)
            }
        }
        try? fm.removeItem(at: dest)
        // --sequesterRsrc would still add __MACOSX/._* for extended attributes (provenance, quarantine), even with
        // COPYFILE_DISABLE=1: leave resource forks, xattrs and ACLs out entirely
        try ditto(["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", copy.path, dest.path])
    }

    // MARK: import

    struct Prepared {
        let root: URL        // temp folder holding everything
        let dir: URL         // the template folder inside it
        let id: String       // suggested id (folder name)
        let manifest: [String: Any]
        var name: String { manifest["name"] as? String ?? id }
        var author: String { manifest["author"] as? String ?? "" }
        func discard() { try? FileManager.default.removeItem(at: root) }
    }

    /// Checks and unpacks a .swtemplate into a temp folder. Blocking: call off the main thread.
    static func prepare(_ file: URL) throws -> Prepared {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw Failure.tooBig }
        guard let data = try? Data(contentsOf: file) else { throw Failure.notZip }
        let entries = try listZip(data)
        try validate(entries)

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("swtemplate-in-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try ditto(["-x", "-k", file.path, root.path])
            try? fm.removeItem(at: root.appendingPathComponent("__MACOSX"))
            try checkTree(root)
            let dir = try templateFolder(in: root, fallbackID: file.deletingPathExtension().lastPathComponent)
            guard let m = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let manifest = (try? JSONSerialization.jsonObject(with: m)) as? [String: Any] else { throw Failure.badManifest }
            let id = dir == root ? file.deletingPathExtension().lastPathComponent : dir.lastPathComponent
            return Prepared(root: root, dir: dir, id: id, manifest: manifest)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    /// Moves a prepared template into `userTemplates` under a free id ("vinyl" → "vinyl-2", name "Vinyl 2").
    /// Returns the id. Blocking file work, but quick.
    static func install(_ p: Prepared, into userTemplates: URL, taken: (String) -> Bool) throws -> String {
        let fm = FileManager.default
        defer { p.discard() }
        var base = p.id.lowercased().replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "template" }
        var id = base, n = 1
        while taken(id) || fm.fileExists(atPath: userTemplates.appendingPathComponent(id).path) {
            n += 1
            id = "\(base)-\(n)"
        }
        if n > 1 {
            var manifest = p.manifest
            manifest["name"] = "\(p.name) \(n)"
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: p.dir.appendingPathComponent("manifest.json"))
        }
        try fm.createDirectory(at: userTemplates, withIntermediateDirectories: true)
        try fm.moveItem(at: p.dir, to: userTemplates.appendingPathComponent(id))
        return id
    }

    /// The folder holding manifest.json + index.html: the archive root or its single top-level folder.
    static func templateFolder(in root: URL, fallbackID: String) throws -> URL {
        let fm = FileManager.default
        let has = { (d: URL, f: String) in fm.fileExists(atPath: d.appendingPathComponent(f).path) }
        var candidates = [root]
        let subs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if subs.count == 1 { candidates.append(subs[0]) }
        for d in candidates where has(d, "manifest.json") {
            guard has(d, "index.html") else { throw Failure.missing("index.html") }
            return d
        }
        throw Failure.missing("manifest.json")
    }

    /// After unpacking: no links, nothing outside the folder, AppleDouble/Finder files removed.
    static func checkTree(_ root: URL) throws {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath().path + "/"
        var total = 0
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else { return }
        for case let f as URL in files {
            let name = f.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { try? fm.removeItem(at: f); continue }
            let v = try? f.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            if v?.isSymbolicLink == true { throw Failure.unsafe(name) }
            guard f.resolvingSymlinksInPath().path.hasPrefix(base) else { throw Failure.unsafe(name) }
            total += v?.fileSize ?? 0
            if total > maxUnpackedBytes { throw Failure.tooBig }
        }
    }

    // MARK: zip central directory (read before unpacking anything)

    struct ZipEntry {
        var name: String
        var size: Int
        var isSymlink: Bool
    }

    static func listZip(_ d: Data) throws -> [ZipEntry] {
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 4 <= b.count ? u16(i) | u16(i + 2) << 16 : 0 }
        guard b.count >= 22 else { throw Failure.notZip }
        // end of central directory: last occurrence of PK\5\6 within the trailing 64 KB comment window
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 65535) {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.notZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        guard count <= maxEntries else { throw Failure.tooBig }
        var out: [ZipEntry] = []
        for _ in 0..<count {
            guard u32(p) == 0x0201_4b50 else { throw Failure.notZip }
            let host = Int(b[p + 5])
            let size = u32(p + 24), nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let attrs = u32(p + 38)
            guard p + 46 + nameLen <= b.count else { throw Failure.notZip }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            if size == 0xFFFF_FFFF { throw Failure.tooBig }  // zip64: far beyond the cap anyway
            let unixMode = host == 3 ? (attrs >> 16) & 0o170000 : 0
            out.append(ZipEntry(name: name, size: size, isSymlink: unixMode == 0o120000))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    static func validate(_ entries: [ZipEntry]) throws {
        var total = 0
        for e in entries {
            let parts = e.name.split(separator: "/", omittingEmptySubsequences: false)
            if e.name.hasPrefix("/") || e.name.contains("\\") || e.name.contains("\0") || parts.contains("..") || e.name.hasPrefix("~") {
                throw Failure.unsafe(e.name)
            }
            if e.isSymlink { throw Failure.unsafe(e.name) }
            total += e.size
            if total > maxUnpackedBytes { throw Failure.tooBig }
        }
        guard entries.contains(where: { $0.name.hasSuffix("manifest.json") }) else { throw Failure.missing("manifest.json") }
    }

    private static func ditto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"
        p.environment = env
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.tool(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: download (spotify-wallpaper://install?url=https://…)

    /// The https URL inside an install link, or nil.
    static func installSource(_ link: URL) -> URL? {
        guard link.scheme?.lowercased() == "spotify-wallpaper", link.host?.lowercased() == "install",
              let raw = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// Downloads to a temp file, giving up past the size cap.
    static func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.download("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard response.url?.scheme?.lowercased() == "https" else { throw Failure.download("redirected away from https") }
        if response.expectedContentLength > maxBytes { throw Failure.tooBig }
        var data = Data()
        data.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(maxBytes)))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw Failure.tooBig }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString).\(fileExtension)")
        try data.write(to: file)
        return file
    }
}

/// The UI side: Export…/Import… panels, double-clicked files and install links, with a confirmation.
@MainActor
final class TemplateInstaller {
    private let store: TemplateStore
    private let paths: Paths
    /// A template was installed: select it.
    var onInstalled: ((String) -> Void)?

    init(store: TemplateStore, paths: Paths) {
        self.store = store
        self.paths = paths
    }

    func export(_ id: String, from window: NSWindow?) {
        guard let t = store.template(id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [TemplatePackage.contentType]
        panel.nameFieldStringValue = t.name.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression) + "." + TemplatePackage.fileExtension
        panel.canCreateDirectories = true
        panel.message = "Anyone with Lirica can double-click this file to install “\(t.name)”."
        let dir = t.dir
        run(panel, in: window) { url in
            Task {
                let error = await Task.detached { () -> String? in
                    do { try TemplatePackage.export(dir, to: url); return nil } catch { return error.localizedDescription }
                }.value
                if let error { Self.alert("Couldn't export “\(t.name)”", error) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    func importWithPanel(from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [TemplatePackage.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a .swtemplate file to install."
        run(panel, in: window) { [weak self] url in self?.installFile(url, confirm: false) }
    }

    /// A double-clicked .swtemplate or a spotify-wallpaper://install link.
    func open(_ url: URL) {
        if url.isFileURL {
            installFile(url, confirm: true)
        } else if let source = TemplatePackage.installSource(url) {
            Task {
                do {
                    let file = try await TemplatePackage.download(source)
                    installFile(file, confirm: true, from: source.host, deleteAfter: true)
                } catch {
                    Self.alert("Couldn't install the template", error.localizedDescription)
                }
            }
        } else if url.scheme?.lowercased() == "spotify-wallpaper" {
            Self.alert("Couldn't install the template", "Install links need an https:// address of a .swtemplate file.")
        }
    }

    private func installFile(_ file: URL, confirm: Bool, from host: String? = nil, deleteAfter: Bool = false) {
        Task {
            let result = await Task.detached { () -> Result<TemplatePackage.Prepared, Error> in
                defer { if deleteAfter { try? FileManager.default.removeItem(at: file) } }
                return Result { try TemplatePackage.prepare(file) }
            }.value
            switch result {
            case .failure(let error):
                Self.alert("Couldn't install the template", error.localizedDescription)
            case .success(let p):
                if confirm && !ask(p, host: host) { p.discard(); return }
                do {
                    let id = try TemplatePackage.install(p, into: paths.userTemplates) { [store] in store.template($0) != nil }
                    store.reload()
                    onInstalled?(id)
                } catch {
                    Self.alert("Couldn't install “\(p.name)”", error.localizedDescription)
                }
            }
        }
    }

    private func ask(_ p: TemplatePackage.Prepared, host: String?) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Install the template “\(p.name)”?"
        var info = p.author.isEmpty ? "" : "By \(p.author). "
        if let d = p.manifest["description"] as? String, !d.isEmpty { info += d + "\n\n" } else if !info.isEmpty { info += "\n\n" }
        if let host { info += "Downloaded from \(host). " }
        info += "Templates are web pages that draw your wallpaper; only install ones from people you trust."
        a.informativeText = info
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func run(_ panel: NSSavePanel, in window: NSWindow?, _ done: @escaping (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { done(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.begin(completionHandler: handler)
        }
    }

    static func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
