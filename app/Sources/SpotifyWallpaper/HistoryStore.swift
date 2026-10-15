import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One saved wallpaper: History/<YYYY-MM>/<id>.jpg (≤1280 px), <id>-thumb.jpg (≤480 px) and <id>.json.
struct HistoryEntry {
    var id: String       // file stem, e.g. 20261007-213455-120-4uLU6hMCjMI75M1A2tKUQC
    var month: String    // YYYY-MM, the folder
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var templateID: String
    var timestamp: Double  // ms since 1970
    var colors: [String: Any]
    var width: Int
    var height: Int

    var json: [String: Any] {
        ["id": id, "month": month, "trackID": trackID, "title": title, "artist": artist, "album": album,
         "template": templateID, "timestamp": timestamp, "colors": colors, "width": width, "height": height]
    }

    init?(json j: [String: Any]) {
        guard let id = j["id"] as? String, let month = j["month"] as? String else { return nil }
        self.id = id
        self.month = month
        trackID = j["trackID"] as? String ?? ""
        title = j["title"] as? String ?? ""
        artist = j["artist"] as? String ?? ""
        album = j["album"] as? String ?? ""
        templateID = j["template"] as? String ?? ""
        timestamp = j["timestamp"] as? Double ?? 0
        colors = j["colors"] as? [String: Any] ?? [:]
        width = j["width"] as? Int ?? 0
        height = j["height"] as? Int ?? 0
    }

    init(id: String, month: String, track: Track, templateID: String, timestamp: Double, colors: [String: Any]) {
        self.init(json: ["id": id, "month": month])!
        trackID = track.id
        title = track.title
        artist = track.artist
        album = track.album
        self.templateID = templateID
        self.timestamp = timestamp
        self.colors = colors
    }

    var date: Date { Date(timeIntervalSince1970: timestamp / 1000) }
}

/// The listening history wall: one wallpaper per song (and per template change), newest last.
/// A still re-rendered during the same play (lyrics arrived, settings tweaked, focus ended) replaces that
/// play's entry instead of adding one. Files are written off the main thread, in order.
@MainActor
final class HistoryStore {
    let maxEntries: Int
    let dir: URL
    private(set) var entries: [HistoryEntry] = []
    private var loaded = false
    /// The play the latest entry belongs to; a different track or template starts a new entry.
    private var current: (trackID: String, templateID: String, entryID: String)?
    private let io = DispatchQueue(label: "SpotifyWallpaper.history")
    var onChange: (() -> Void)?

    init(dir: URL, maxEntries: Int = 2000) {
        self.dir = dir
        self.maxEntries = maxEntries
    }

    convenience init(paths: Paths) { self.init(dir: Self.directory(paths)) }

    nonisolated static func directory(_ paths: Paths) -> URL { paths.support.appendingPathComponent("History") }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepHistory") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepHistory") }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        entries = Self.scan(dir)
    }

    nonisolated static func scan(_ dir: URL) -> [HistoryEntry] {
        let fm = FileManager.default
        var out: [HistoryEntry] = []
        for month in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
                guard let d = try? Data(contentsOf: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let e = HistoryEntry(json: j) else { continue }
                out.append(e)
            }
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }

    func entry(_ id: String) -> HistoryEntry? { entries.first { $0.id == id } }
    func imageURL(_ e: HistoryEntry) -> URL { dir.appendingPathComponent(e.month).appendingPathComponent(e.id + ".jpg") }
    func thumbURL(_ e: HistoryEntry) -> URL { dir.appendingPathComponent(e.month).appendingPathComponent(e.id + "-thumb.jpg") }

    /// Called with each finished still for the primary screen.
    func record(_ jpeg: Data, track: Track, templateID: String, colors: [String: Any]) {
        guard enabled, track.id != "sample" else { return }
        load()
        let now = Date()
        var entry: HistoryEntry
        if let c = current, c.trackID == track.id, c.templateID == templateID, let i = entries.firstIndex(where: { $0.id == c.entryID }) {
            entry = entries[i]  // same play: replace the picture, keep the slot
            entry.colors = colors
        } else {
            let stamp = Self.stampFormatter.string(from: now)
            let safe = track.id.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression).suffix(40)
            entry = HistoryEntry(id: "\(stamp)-\(safe)", month: String(stamp.prefix(4) + "-" + stamp.dropFirst(4).prefix(2)),
                                 track: track, templateID: templateID, timestamp: now.timeIntervalSince1970 * 1000, colors: colors)
        }
        current = (track.id, templateID, entry.id)
        let folder = dir.appendingPathComponent(entry.month), snapshot = entry
        io.async { [weak self] in
            guard let (w, h) = Self.write(jpeg, entry: snapshot, folder: folder) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    var e = snapshot
                    (e.width, e.height) = (w, h)
                    if let i = self.entries.firstIndex(where: { $0.id == e.id }) { self.entries[i] = e } else { self.entries.append(e) }
                    self.prune()
                    self.onChange?()
                }
            }
        }
    }

    /// Writes the downscaled picture, its thumbnail and the metadata. Returns the picture's pixel size.
    nonisolated static func write(_ jpeg: Data, entry: HistoryEntry, folder: URL) -> (Int, Int)? {
        guard let big = downscale(jpeg, maxPixels: 1280), let small = downscale(jpeg, maxPixels: 480),
              let bigData = encodeJPEG(big, quality: 0.85), let smallData = encodeJPEG(small, quality: 0.8) else { return nil }
        var e = entry
        (e.width, e.height) = (big.width, big.height)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bigData.write(to: folder.appendingPathComponent(e.id + ".jpg"), options: .atomic)
            try smallData.write(to: folder.appendingPathComponent(e.id + "-thumb.jpg"), options: .atomic)
            try JSONSerialization.data(withJSONObject: e.json, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent(e.id + ".json"), options: .atomic)
        } catch {
            NSLog("SpotifyWallpaper: couldn't save history: \(error)")
            return nil
        }
        return (big.width, big.height)
    }

    private func prune() {
        guard entries.count > maxEntries else { return }
        let old = Array(entries.prefix(entries.count - maxEntries))
        entries.removeFirst(old.count)
        let dir = dir
        io.async { Self.remove(old, in: dir) }
    }

    nonisolated static func remove(_ old: [HistoryEntry], in dir: URL) {
        let fm = FileManager.default
        for e in old {
            let folder = dir.appendingPathComponent(e.month)
            for suffix in [".jpg", "-thumb.jpg", ".json"] { try? fm.removeItem(at: folder.appendingPathComponent(e.id + suffix)) }
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
        }
    }

    func clear() {
        entries.removeAll()
        current = nil
        let dir = dir
        io.async { try? FileManager.default.removeItem(at: dir) }
        onChange?()
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    // MARK: image helpers

    nonisolated static func downscale(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    nonisolated static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        encode(image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    nonisolated static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// Contact sheets and GIFs made from history pictures. Pure Core Graphics / ImageIO, safe off the main thread.
enum HistoryExport {
    struct Item {
        var image: URL
        var title: String
        var subtitle: String
    }

    static let maxSheetItems = 600
    static let maxGIFFrames = 120

    /// One PNG: a heading, then a grid of tiles with two small caption lines under each.
    static func contactSheet(_ items: [Item], heading: String) -> Data? {
        let items = Array(items.suffix(maxSheetItems))  // the newest
        guard !items.isEmpty else { return nil }
        let cols = min(16, max(4, Int(ceil(sqrt(Double(items.count) * 1.4)))))
        let rows = Int(ceil(Double(items.count) / Double(cols)))
        let tileW: CGFloat = items.count > 200 ? 240 : 320, gap: CGFloat = 20, margin: CGFloat = 48, captionH: CGFloat = 40, headH: CGFloat = 76
        let aspect = firstAspect(items) ?? (10.0 / 16.0)
        let tileH = (tileW * aspect).rounded()
        let width = Int(margin * 2 + CGFloat(cols) * tileW + CGFloat(cols - 1) * gap)
        let height = Int(margin * 2 + headH + CGFloat(rows) * (tileH + captionH) + CGFloat(rows - 1) * gap)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // flip so y grows downwards, like the layout above
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(srgbRed: 0.086, green: 0.086, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high

        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }

        let white = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1), grey = NSColor(srgbRed: 0.63, green: 0.63, blue: 0.65, alpha: 1)
        draw(heading, in: CGRect(x: margin, y: margin, width: CGFloat(width) - margin * 2, height: 40),
             font: .systemFont(ofSize: 30, weight: .bold), color: white)
        draw("Lirica · listening history", in: CGRect(x: margin, y: margin + 40, width: CGFloat(width) - margin * 2, height: 24),
             font: .systemFont(ofSize: 15, weight: .regular), color: grey)

        for (i, item) in items.enumerated() {
            let x = margin + CGFloat(i % cols) * (tileW + gap)
            let y = margin + headH + CGFloat(i / cols) * (tileH + captionH + gap)
            let box = CGRect(x: x, y: y, width: tileW, height: tileH)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.clip()
            ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
            ctx.fill(box)
            if let img = loadImage(item.image, maxPixels: Int(tileW * 2)) {
                // aspect-fill the tile; draw upright in the flipped context
                let s = max(box.width / CGFloat(img.width), box.height / CGFloat(img.height))
                let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
                let r = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
                ctx.translateBy(x: 0, y: r.maxY + r.minY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: r)
            }
            ctx.restoreGState()
            draw(item.title, in: CGRect(x: x, y: y + tileH + 6, width: tileW, height: 17), font: .systemFont(ofSize: 13, weight: .semibold), color: white)
            draw(item.subtitle, in: CGRect(x: x, y: y + tileH + 22, width: tileW, height: 16), font: .systemFont(ofSize: 11.5), color: grey)
        }
        guard let image = ctx.makeImage() else { return nil }
        return HistoryStore.encode(image, type: .png)
    }

    /// An endlessly looping GIF, `width` px wide, ~0.5 s per picture; long selections are sampled evenly.
    static func gif(_ images: [URL], width: Int = 960, delay: Double = 0.5) -> Data? {
        guard !images.isEmpty else { return nil }
        let picked: [URL] = images.count <= maxGIFFrames ? images
            : (0..<maxGIFFrames).map { images[Int(Double($0) * Double(images.count) / Double(maxGIFFrames))] }
        let aspect = firstAspect(picked.map { Item(image: $0, title: "", subtitle: "") }) ?? (10.0 / 16.0)
        let height = Int((CGFloat(width) * aspect).rounded())
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, picked.count, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        var frames = 0
        for url in picked {
            guard let img = loadImage(url, maxPixels: width * 2),
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { continue }
            ctx.interpolationQuality = .high
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let s = max(CGFloat(width) / CGFloat(img.width), CGFloat(height) / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            ctx.draw(img, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
            guard let frame = ctx.makeImage() else { continue }
            CGImageDestinationAddImage(dest, frame, frameProps)
            frames += 1
        }
        guard frames > 0, CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func loadImage(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return HistoryStore.downscale(data, maxPixels: maxPixels)
    }

    /// height / width of the first readable picture.
    private static func firstAspect(_ items: [Item]) -> CGFloat? {
        for item in items {
            guard let src = CGImageSourceCreateWithURL(item.image as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0 else { continue }
            return CGFloat(h) / CGFloat(w)
        }
        return nil
    }

    private static func draw(_ text: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}
